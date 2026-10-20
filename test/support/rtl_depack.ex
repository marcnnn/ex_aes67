defmodule ExAes67.RTLDepack do
  @moduledoc false
  # Drives the RTL depacketiser and the model with the same table and packets.
  import Bitwise
  alias ExAes67.RTLDrv, as: D
  alias ExAes67.RTL.{Depacketiser, Program}
  alias ExAes67.Model.Depacketiser, as: Model

  @doc "AXI4-Stream beats of a UDP payload: `{tdata, tkeep, tlast, tuser}`."
  def beats(dst_ip, dst_port, payload) do
    len = byte_size(payload)
    tuser = Program.ip(dst_ip) ||| dst_port <<< 32 ||| len <<< 80

    chunks = for <<c::binary-size(8) <- payload>>, do: c
    rest = binary_part(payload, length(chunks) * 8, rem(len, 8))
    chunks = if rest == <<>>, do: chunks, else: chunks ++ [rest]
    last = length(chunks) - 1

    for {c, i} <- Enum.with_index(chunks) do
      n = byte_size(c)
      <<v::little-64>> = c <> :binary.copy(<<0>>, 8 - n)
      {v, (1 <<< n) - 1, if(i == last, do: 1, else: 0), if(i == 0, do: tuser, else: 0)}
    end
  end

  @doc """
  Options: module options (`:streams`, `:hash_bits`, `:bank_words`), `:ready`
  (percent, default 100) and `:idle` (max idle cycles between beats' groups, default 0), `:seed`.
  Returns a map with the RTL and model results and the driver.
  """
  def run(entries, packets, opts \\ []) do
    mod_opts = Keyword.take(opts, [:streams, :hash_bits, :bank_words])
    mod = Depacketiser.build(mod_opts)
    :rand.seed(:exsss, {Keyword.get(opts, :seed, 1), 7, 8})
    ready = Keyword.get(opts, :ready, 100)
    idle = Keyword.get(opts, :idle, 0)

    {prog, index} = Program.rx(entries, mod_opts)
    d = D.new(mod)

    d =
      Enum.reduce(prog, d, fn w, d -> d |> D.set(w) |> D.step() end)
      |> D.set(%{cfg_we: 0})

    {d, got} =
      Enum.reduce(packets, {d, []}, fn {ip, port, payload}, {d, got} ->
        Enum.reduce(beats(ip, port, payload), {d, got}, fn beat, {d, got} ->
          {d, got} = send_beat(d, beat, got, ready)
          maybe_idle(d, got, idle, ready)
        end)
      end)

    {d, got} = drain(d, got, ready, 0)
    got = got |> Enum.reverse() |> List.flatten()

    {model, mw, results} =
      Enum.reduce(packets, {Model.new(entries), [], []}, fn {ip, port, payload}, {m, w, r} ->
        {m, writes, res} = Model.process(m, ip, port, payload)
        {m, w ++ writes, r ++ [res]}
      end)

    stats =
      for e <- entries, into: %{} do
        {e.id, read_stats(d, index[e.id])}
      end

    glob = Map.new(Depacketiser.stats(), &{&1, D.peek(d, :"st_#{&1}")})

    %{
      writes: got,
      model_writes: mw,
      stats: stats,
      model: model,
      results: results,
      globals: glob,
      drv: d
    }
  end

  defp read_stats(d, i) do
    d = D.set(d, %{stat_addr: i, stat_lane: 0}) |> D.step()

    Map.new([packets: 0, lost: 1, reordered: 2, samples: 3], fn {k, lane} ->
      d = D.set(d, %{stat_lane: lane}) |> D.step()
      {k, D.peek(d, :stat_data)}
    end)
  end

  defp send_beat(d, {data, keep, last, user} = beat, got, ready, tries \\ 0)
       when tries < 100_000 do
    d =
      D.set(d, %{
        s_axis_tvalid: 1,
        s_axis_tdata: data,
        s_axis_tkeep: keep,
        s_axis_tlast: last,
        s_axis_tuser: user
      })

    {d, got, accepted} = cycle(d, got, ready)

    if accepted,
      do: {D.set(d, %{s_axis_tvalid: 0}), got},
      else: send_beat(d, beat, got, ready, tries + 1)
  end

  # One clock: choose wr_ready, record a sample write if valid and ready, step.
  defp cycle(d, got, ready) do
    rdy = if :rand.uniform(100) <= ready, do: 1, else: 0
    d = D.set(d, %{wr_ready: rdy})
    accepted = D.peek(d, :s_axis_tvalid) == 1 and D.peek(d, :s_axis_tready) == 1

    got =
      if D.peek(d, :wr_valid) == 1 and rdy == 1,
        do: [{D.peek(d, :wr_ch), D.peek(d, :wr_ts), D.peek(d, :wr_data)} | got],
        else: got

    {D.step(d), got, accepted}
  end

  defp maybe_idle(d, got, 0, _), do: {d, got}

  defp maybe_idle(d, got, idle, ready) do
    n = :rand.uniform(idle + 1) - 1

    Enum.reduce(1..n//1, {d, got}, fn _, {d, got} ->
      cycle(d, got, ready) |> Tuple.delete_at(2)
    end)
  end

  defp drain(d, got, ready, i) when i < 200_000 do
    busy =
      D.peek(d, :pst) != 0 or D.peek(d, :full0) == 1 or D.peek(d, :full1) == 1 or
        D.peek(d, :wr_valid) == 1

    if busy do
      {d, got, _} = cycle(d, got, ready)
      drain(d, got, ready, i + 1)
    else
      {d, got}
    end
  end
end
