defmodule ExAes67.RTLRx do
  @moduledoc false
  # Receive path in RTL and in the models, fed with the same arrivals per media tick.
  import Bitwise
  alias ExAes67.RTLDrv, as: D
  alias ExAes67.RTLDepack
  alias ExAes67.RTL.Program
  alias ExAes67.Model.{Depacketiser, JitterBuffer}

  @doc """
  `arrivals` maps a media tick to `[{dst_ip, dst_port, udp_payload}]`. Plays ticks `0..ticks`
  with `rtp_ts = (tick + rtp0) mod 2^32`. Options: `:latency`, `:depth`, `:channels`.
  Returns `%{frames, jb_stats, dp_stats, drv}`.
  """
  def run_rtl(entries, arrivals, ticks, rtp0, opts) do
    mod = ExAes67.RTL.Rx.build(opts ++ [streams: 8, hash_bits: 3])
    d = D.new(mod, %{latency: opts[:latency], rtp_ts: rtp0 - 1 &&& 0xFFFFFFFF})
    {prog, index} = Program.rx(entries, streams: 8, hash_bits: 3)
    d = Enum.reduce(prog, d, fn w, d -> d |> D.set(w) |> D.step() end) |> D.set(%{cfg_we: 0})
    n = Keyword.fetch!(opts, :channels)

    {d, frames} =
      Enum.reduce(0..ticks, {d, %{}}, fn now, {d, frames} ->
        d =
          Enum.reduce(Map.get(arrivals, now, []), d, fn {ip, port, bin}, d ->
            Enum.reduce(RTLDepack.beats(ip, port, bin), d, &beat(&2, &1))
          end)

        d = quiet(d)
        d = D.set(d, %{tick: 1, rtp_ts: now + rtp0 &&& 0xFFFFFFFF}) |> D.step()
        {d, frame} = d |> D.set(%{tick: 0}) |> collect(n, [])
        {d, Map.put(frames, now, frame)}
      end)

    jb = Map.new(ExAes67.RTL.JitterBuffer.stats(), &{&1, D.peek(d, :"jb_#{&1}")})

    dp =
      for e <- entries, into: %{} do
        {e.id, stats(d, index[e.id])}
      end

    %{frames: frames, jb_stats: jb, dp_stats: dp, drv: d}
  end

  defp stats(d, i) do
    d = D.set(d, %{stat_addr: i})

    Map.new([packets: 0, lost: 1, reordered: 2, samples: 3], fn {k, lane} ->
      d = D.set(d, %{stat_lane: lane}) |> D.step()
      {k, D.peek(d, :stat_data)}
    end)
  end

  defp beat(d, {data, keep, last, user}) do
    d =
      D.set(d, %{
        s_axis_tvalid: 1,
        s_axis_tdata: data,
        s_axis_tkeep: keep,
        s_axis_tlast: last,
        s_axis_tuser: user
      })

    wait_ready(d)
  end

  defp wait_ready(d, i \\ 0) when i < 100_000 do
    if D.peek(d, :s_axis_tready) == 1,
      do: d |> D.step() |> D.set(%{s_axis_tvalid: 0}),
      else: d |> D.step() |> wait_ready(i + 1)
  end

  defp quiet(d, i \\ 0) when i < 100_000 do
    busy =
      for p <- ["dp.pst", "dp.full0", "dp.full1", "dp.o_valid", "jb.w_busy"], reduce: false do
        acc -> acc or D.peek(d, p) != 0
      end

    if busy, do: d |> D.step() |> quiet(i + 1), else: d
  end

  defp collect(d, n, acc, i \\ 0) when i < 100 + 4 * n do
    acc = if D.peek(d, :out_valid) == 1, do: [D.peek(d, :out_data) | acc], else: acc

    if D.peek(d, :out_last) == 1,
      do: {D.step(d), Enum.reverse(acc)},
      else: d |> D.step() |> collect(n, acc, i + 1)
  end

  @doc "Same arrivals through the models (as in `ExAes67.E2ETest`)."
  def run_model(entries, arrivals, ticks, rtp0, opts) do
    jb =
      JitterBuffer.new(
        depth: opts[:depth],
        channels: opts[:channels],
        latency: opts[:latency],
        now: rtp0 &&& 0xFFFFFFFF
      )

    {frames, jb, dp} =
      Enum.reduce(0..ticks, {%{}, jb, Depacketiser.new(entries)}, fn now, {frames, jb, dp} ->
        {jb, dp} =
          Enum.reduce(Map.get(arrivals, now, []), {jb, dp}, fn {ip, port, bin}, {jb, dp} ->
            {dp, writes, _} = Depacketiser.process(dp, ip, port, bin)
            {jb, _} = JitterBuffer.write_all(jb, writes)
            {jb, dp}
          end)

        {jb, frame} = JitterBuffer.play(jb, now + rtp0 &&& 0xFFFFFFFF)
        {Map.put(frames, now, frame), jb, dp}
      end)

    %{frames: frames, jb_stats: jb.stats, dp_stats: dp.stats}
  end
end
