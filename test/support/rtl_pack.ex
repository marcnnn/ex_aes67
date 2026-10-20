defmodule ExAes67.RTLPack do
  @moduledoc false
  # Drives the RTL packetiser and the model with the same samples and ticks.
  import Bitwise
  alias ExAes67.RTLDrv, as: D
  alias ExAes67.RTL.Program
  alias ExAes67.Model.SampleRing
  alias ExAes67.Model.Packetiser, as: Model

  @doc "Beats `{tdata, tkeep, tlast, tuser}` to a binary."
  def bytes(beats) do
    for {v, keep, _, _} <- beats, into: <<>> do
      n = Integer.digits(keep, 2) |> Enum.sum()
      binary_part(<<v::little-64>>, 0, n)
    end
  end

  @doc """
  `sample.(ch, t)` returns the sample for channel `ch` at media time `t` or `nil` to skip the write.
  Options: `:ticks`, `:period` (cycles per tick), `:ready` (percent), `:seed`, `:now` (first tick),
  `:depth`, `:tag_bits`, `:channels`.
  Returns `%{rtl: [{tick, stream_id_key, bytes, tuser}], model: [{tick, pkt}], ...}`.
  """
  def run(cfgs, sample, opts) do
    nch = Keyword.fetch!(opts, :channels)
    ticks = Keyword.fetch!(opts, :ticks)
    period = Keyword.fetch!(opts, :period)
    now0 = Keyword.get(opts, :now, 0)
    ready = Keyword.get(opts, :ready, 100)
    depth = Keyword.get(opts, :depth, 64)

    mod =
      ExAes67.RTL.Packetiser.build(
        streams: max(length(cfgs), 2),
        channels: nch,
        depth: depth,
        tag_bits: Keyword.get(opts, :tag_bits, 32)
      )

    :rand.seed(:exsss, {Keyword.get(opts, :seed, 1), 3, 9})
    d = D.new(mod)
    d = Enum.reduce(Program.tx(cfgs, now0), d, fn w, d -> d |> D.set(w) |> D.step() end)
    d = D.set(d, %{cfg_we: 0})

    model = Model.new(cfgs, now: now0)
    ring = SampleRing.new(depth: depth)

    {d, model, _, rtl_pkts, model_pkts} =
      Enum.reduce(now0..(now0 + ticks - 1), {d, model, ring, [], []}, fn t,
                                                                         {d, model, ring, rp, mp} ->
        ring =
          Enum.reduce(0..(nch - 1), ring, fn c, ring ->
            case sample.(c, t) do
              nil -> ring
              v -> SampleRing.write(ring, c, t, v)
            end
          end)

        {model, pkts} = Model.tick(model, ring, t)
        {d, got} = cycles(d, t, nch, period, sample, ready)

        {d, model, ring, rp ++ Enum.map(got, &Tuple.insert_at(&1, 0, t)),
         mp ++ Enum.map(pkts, &{t, &1})}
      end)

    stats = Map.new(ExAes67.RTL.Packetiser.stats(), &{&1, D.peek(d, :"st_#{&1}")})
    %{rtl: rtl_pkts, model: model_pkts, stats: stats, model_stats: model.stats, drv: d}
  end

  defp cycles(d, t, nch, period, sample, ready) do
    d = D.set(d, %{tick: 1, rtp_ts: t &&& 0xFFFFFFFF, in_valid: 0})
    {d, beats, got} = tick_cycle(d, [], [], ready)
    d = D.set(d, %{tick: 0})

    {d, beats, got} =
      Enum.reduce(0..(nch - 1), {d, beats, got}, fn c, {d, beats, got} ->
        d =
          case sample.(c, t) do
            nil -> D.set(d, %{in_valid: 0})
            v -> D.set(d, %{in_valid: 1, in_ch: c, in_data: v})
          end

        tick_cycle(d, beats, got, ready)
      end)

    d = D.set(d, %{in_valid: 0})

    {d, beats, got} =
      Enum.reduce(1..(period - nch - 1)//1, {d, beats, got}, fn _, {d, b, g} ->
        tick_cycle(d, b, g, ready)
      end)

    # all beats of a packet must have arrived
    true = beats == []
    {d, Enum.reverse(got)}
  end

  defp tick_cycle(d, beats, got, ready) do
    rdy = if :rand.uniform(100) <= ready, do: 1, else: 0
    d = D.set(d, %{m_axis_tready: rdy})

    {beats, got} =
      if D.peek(d, :m_axis_tvalid) == 1 and rdy == 1 do
        beat =
          {D.peek(d, :m_axis_tdata), D.peek(d, :m_axis_tkeep), D.peek(d, :m_axis_tlast),
           D.peek(d, :m_axis_tuser)}

        beats = [beat | beats]

        if elem(beat, 2) == 1 do
          bs = Enum.reverse(beats)
          {[], [{bytes(bs), elem(hd(bs), 3)} | got]}
        else
          {beats, got}
        end
      else
        {beats, got}
      end

    {D.step(d), beats, got}
  end
end
