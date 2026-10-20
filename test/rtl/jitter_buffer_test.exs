defmodule ExAes67.RTL.JitterBufferTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise
  alias ExAes67.RTLJb

  @configs [
    [channels: 5, depth: 8, tag_bits: 32],
    [channels: 5, depth: 8, tag_bits: 11],
    [channels: 4, depth: 16, tag_bits: 32]
  ]

  defp periods(now0, ticks, latency, depth, n) do
    for {now, writes} <- Enum.with_index(ticks, now0) |> Enum.map(fn {w, now} -> {now, w} end) do
      {now,
       for {ch, delta, data} <- writes do
         {ch, now - latency + delta - 1 &&& 0xFFFFFFFF, data}
       end}
      |> then(fn {now, w} -> {now, w} end)
    end
    |> tap(fn _ -> {depth, n} end)
  end

  defp write_gen(n, depth) do
    tuple({integer(0..(n + 1)), integer(-3..(depth + 2)), integer(-8_388_608..8_388_607)})
  end

  for cfg <- @configs do
    @cfg cfg
    test "matches the model on random traffic #{inspect(cfg)}" do
      cfg = @cfg
      n = cfg[:channels]
      depth = cfg[:depth]

      check all(
              now0 <- one_of([integer(0..1000), integer(0xFFFFFFF0..0xFFFFFFFF)]),
              latency <- integer(0..(depth - 1)),
              gap <- integer(0..2),
              ticks <-
                list_of(list_of(write_gen(n, depth), max_length: 6),
                  min_length: 4,
                  max_length: 24
                ),
              max_runs: 12
            ) do
        ps = periods(now0, ticks, latency, depth, n)
        {rtl, mdl, srtl, smdl, _} = RTLJb.run(cfg, latency, ps, gap)
        assert rtl == mdl
        assert Map.delete(srtl, :tick_overrun) == smdl |> Map.delete(:tick_overrun)
        assert srtl.tick_overrun == 0
      end
    end
  end

  describe "writes while the scan runs" do
    alias ExAes67.RTLDrv, as: D

    defp scan_setup do
      mod = ExAes67.RTL.JitterBuffer.build(channels: 4, depth: 8, tag_bits: 32)
      {mod, D.new(mod, %{latency: 2, rtp_ts: 9})}
    end

    # writes one sample, recording the playout words seen meanwhile
    defp write1({d, seen}, ch, ts, v) do
      {d, seen} = {D.set(d, %{wr_valid: 1, wr_ch: ch, wr_ts: ts, wr_data: v}), seen}
      {d, seen} = until_ready({d, seen})
      {d, seen} = step1({d, seen})
      {D.set(d, %{wr_valid: 0}), seen}
    end

    defp until_ready({d, seen}),
      do: if(D.peek(d, :wr_ready) == 1, do: {d, seen}, else: until_ready(step1({d, seen})))

    defp step1({d, seen}) do
      seen =
        if D.peek(d, :out_valid) == 1,
          do: [{D.peek(d, :out_ch), D.peek(d, :out_data)} | seen],
          else: seen

      {D.step(d), seen}
    end

    test "play instant is per channel: ahead of the scan is on time, behind it is late" do
      {_, d} = scan_setup()
      # tick at now = 10 plays frame 8; the scan reads one channel per cycle from the next cycle
      d = D.set(d, %{tick: 1, rtp_ts: 10}) |> D.step() |> D.set(%{tick: 0})
      acc = {d, []}

      # channel 3 is still ahead of the scan: frame 8 is on time (and collides with its read), frame 16 would clobber it
      acc = write1(acc, 3, 16, 5)
      acc = write1(acc, 3, 8, 333)
      # channel 0 was played: frame 8 is late, the next lap is fine
      acc = Enum.reduce(1..6, acc, fn _, acc -> step1(acc) end)
      acc = write1(acc, 0, 8, 111)
      acc = write1(acc, 1, 16, 222)
      {d, seen} = Enum.reduce(1..6, acc, fn _, acc -> step1(acc) end)
      assert D.peek(d, :st_late) == 1
      assert D.peek(d, :st_overrun) == 1
      assert D.peek(d, :st_written) == 2
      assert D.peek(d, :st_played) == 1
      assert Enum.sort(seen) == [{0, 0}, {1, 0}, {2, 0}, {3, 333}]
    end

    test "random traffic during scans: Verilator agrees with the BEAM simulator" do
      {_, d} = scan_setup()
      :rand.seed(:exsss, {3, 3, 3})

      {d, coll} =
        Enum.reduce(0..1500, {d, 0}, fn i, {d, coll} ->
          now = 10 + div(i, 30)

          d =
            D.set(d, %{
              tick: if(rem(i, 30) == 0, do: 1, else: 0),
              rtp_ts: now,
              wr_valid: if(:rand.uniform(100) <= 70, do: 1, else: 0),
              wr_ch: :rand.uniform(4) - 1,
              wr_ts: now - 2 - 1 + :rand.uniform(9),
              wr_data: :rand.uniform(1000)
            })

          {D.step(d), coll + D.peek(d, :coll)}
        end)

      assert coll > 0
      assert D.cosim(d) == :ok
    end
  end

  @tag :verilator
  @tag timeout: 300_000
  test "Verilator reproduces random traffic with the model checked BEAM run" do
    :rand.seed(:exsss, {1, 1, 1})

    ps =
      for now <- 100..140 do
        {now,
         for(
           _ <- 1..:rand.uniform(6),
           do: {:rand.uniform(6) - 1, now - 4 + :rand.uniform(12) - 2, :rand.uniform(1000)}
         )}
      end

    for cfg <- @configs do
      {rtl, mdl, _, _, d} = RTLJb.run(cfg, 3, ps, 1)
      assert rtl == mdl
      assert ExAes67.RTLDrv.cosim(d) == :ok
    end
  end
end
