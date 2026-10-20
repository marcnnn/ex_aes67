defmodule ExAes67.RTLJb do
  @moduledoc false
  # Drives the RTL jitter buffer and the model with the same writes and ticks.
  import Bitwise
  alias ExAes67.RTLDrv, as: D
  alias ExAes67.Model.JitterBuffer, as: Model

  @stats ExAes67.RTL.JitterBuffer.stats()

  @doc """
  `periods` is `[{now, [{ch, ts, sample}]}]`: the writes arriving before the
  tick of media time `now`. Returns `{frames_rtl, frames_model, stats_rtl,
  stats_model, drv}`.
  """
  def run(opts, latency, periods, gap \\ 0) do
    mod = ExAes67.RTL.JitterBuffer.build(opts)
    n = Keyword.fetch!(opts, :channels)
    {now0, _} = hd(periods)
    d = D.new(mod, %{latency: latency, rtp_ts: now0 - 1 &&& 0xFFFFFFFF})

    model =
      Model.new(
        depth: Keyword.fetch!(opts, :depth),
        channels: n,
        latency: latency,
        now: now0 &&& 0xFFFFFFFF
      )

    {d, model, rtl, mdl} =
      Enum.reduce(periods, {d, model, [], []}, fn {now, writes}, {d, model, rtl, mdl} ->
        d = Enum.reduce(writes, d, &write(&2, &1, gap))
        d = settle(d)
        {model, _} = Model.write_all(model, writes)
        {model, frame} = Model.play(model, now &&& 0xFFFFFFFF)
        {d, got} = tick(d, now, n)
        {d, model, [got | rtl], [frame | mdl]}
      end)

    stats = Map.new(@stats, &{&1, D.peek(d, :"st_#{&1}")})
    {Enum.reverse(rtl), Enum.reverse(mdl), stats, model.stats, d}
  end

  defp write(d, {ch, ts, sample}, gap) do
    d = D.set(d, %{wr_valid: 1, wr_ch: ch, wr_ts: ts &&& 0xFFFFFFFF, wr_data: sample})
    d = push(d, 0)
    d = D.set(d, %{wr_valid: 0})
    if gap > 0, do: D.step(d, gap), else: d
  end

  defp push(d, i) when i < 20 do
    if D.peek(d, :wr_ready) == 1, do: D.step(d), else: push(D.step(d), i + 1)
  end

  defp settle(d) do
    if D.peek(d, :w_busy) == 1, do: settle(D.step(d)), else: d
  end

  defp tick(d, now, n) do
    d = D.set(d, %{tick: 1, rtp_ts: now &&& 0xFFFFFFFF}) |> D.step()
    d = D.set(d, %{tick: 0})
    collect(d, n, [], 0)
  end

  defp collect(d, n, acc, i) when i < 4 * n + 20 do
    acc =
      if D.peek(d, :out_valid) == 1,
        do: [{D.peek(d, :out_ch), D.peek(d, :out_data)} | acc],
        else: acc

    if D.peek(d, :out_last) == 1 do
      # let the last registered word and the scan state settle
      {D.step(d), acc |> Enum.reverse() |> Enum.map(&elem(&1, 1)), n}
      |> then(fn {d, frame, _} -> {d, frame} end)
    else
      collect(D.step(d), n, acc, i + 1)
    end
  end
end
