defmodule ExAes67.E2ETest do
  @moduledoc "Packetiser -> simulated network -> depacketiser -> jitter buffer."
  use ExUnit.Case, async: true
  import Bitwise
  alias ExAes67.TestNet
  alias ExAes67.Model.{Depacketiser, JitterBuffer, Packetiser, SampleRing}

  @latency 128
  @ticks 1500
  @settle 300

  # stream a: 2 ch L24 1 ms on channels 0-1, stream b: 1 ch L16 250 us on channel 2
  defp tx_cfgs(offset) do
    [
      %{
        id: :a,
        channels: 2,
        base_channel: 0,
        ptime_us: 1000,
        format: :l24,
        pt: 97,
        ssrc: 0xA,
        dst_ip: {239, 1, 1, 1},
        dst_port: 5004,
        ts_offset: offset
      },
      %{
        id: :b,
        channels: 1,
        base_channel: 2,
        ptime_us: 250,
        format: :l16,
        pt: 98,
        ssrc: 0xB,
        dst_ip: {239, 1, 1, 2},
        dst_port: 6000,
        ts_offset: offset,
        seq0: 65_500
      }
    ]
  end

  defp rx_table do
    [
      %{
        id: :a,
        dst_ip: {239, 1, 1, 1},
        dst_port: 5004,
        ssrc: nil,
        pt: 97,
        channels: 2,
        base_channel: 0,
        format: :l24
      },
      %{
        id: :b,
        dst_ip: {239, 1, 1, 2},
        dst_port: 6000,
        ssrc: 0xB,
        pt: 98,
        channels: 1,
        base_channel: 2,
        format: :l16
      }
    ]
  end

  # distinct, never zero, L16-exact for channel 2
  defp sample(0, t), do: 1 + rem(t * 7919, 8_000_000)
  defp sample(1, t), do: -1 - rem(t * 104_729, 8_000_000)
  defp sample(2, t), do: (1 + rem(t, 30_000)) * 256

  defp run(net_opts, offset, rx_skew \\ 0) do
    ring = SampleRing.new(depth: 512)

    {_, _, sent} =
      Enum.reduce(0..(@ticks - 1), {ring, Packetiser.new(tx_cfgs(offset)), []}, fn t,
                                                                                   {ring, p, sent} ->
        ring = Enum.reduce(0..2, ring, &SampleRing.write(&2, &1, t, sample(&1, t)))
        {p, pkts} = Packetiser.tick(p, ring, t)
        {ring, p, sent ++ Enum.map(pkts, &{t, &1})}
      end)

    arrivals = TestNet.deliver(sent, net_opts)
    by_time = Enum.group_by(arrivals, &elem(&1, 0), &elem(&1, 1))

    {frames, jb, dp} =
      Enum.reduce(
        0..(@ticks + @settle),
        {%{},
         JitterBuffer.new(
           depth: 256,
           channels: 3,
           latency: @latency,
           now: offset + rx_skew &&& 0xFFFFFFFF
         ), Depacketiser.new(rx_table())},
        fn now, {frames, jb, dp} ->
          {jb, dp} =
            Enum.reduce(Map.get(by_time, now, []), {jb, dp}, fn pkt, {jb, dp} ->
              {dp, writes, _} =
                Depacketiser.process(dp, pkt.dst_ip, pkt.dst_port, pkt.udp_payload)

              {jb, _} = JitterBuffer.write_all(jb, writes)
              {jb, dp}
            end)

          {jb, frame} = JitterBuffer.play(jb, now + offset + rx_skew &&& 0xFFFFFFFF)
          {Map.put(frames, now, frame), jb, dp}
        end
      )

    {frames, jb, dp, sent}
  end

  defp expected(t), do: [sample(0, t), sample(1, t), sample(2, t)]

  test "clean network with reordering jitter: original samples at the right media time" do
    {frames, jb, dp, _} = run([base: 20, jitter: 40, seed: 1], 0)
    # playout tick n shows the frame sent at media time n - latency
    for n <- @latency..(@ticks - 200),
        do: assert(frames[n] == expected(n - @latency), "tick #{n}")

    assert jb.stats.late == 0 and jb.stats.overrun == 0 and jb.stats.duplicate == 0
    assert dp.stats[:a].reordered > 0 or dp.stats[:b].reordered > 0
    for id <- [:a, :b], do: assert(abs(dp.stats[id].lost - dp.stats[id].reordered) <= 1)
  end

  test "RTP timestamp and sequence wraparound (mediaclk offset near 2^32)" do
    {frames, jb, dp, sent} = run([base: 10, jitter: 60, seed: 5], 0xFFFFFF00)

    for n <- @latency..(@ticks - 200),
        do: assert(frames[n] == expected(n - @latency), "tick #{n}")

    assert jb.stats.late == 0
    assert Enum.any?(sent, fn {_, p} -> p.stream == :b and p.rtp.seq < 100 end)
    assert Enum.any?(sent, fn {_, p} -> p.stream == :a and p.rtp.ts < 0x1000 end)
    assert abs(dp.stats[:b].lost - dp.stats[:b].reordered) <= 1
  end

  test "duplicates are absorbed" do
    {frames, jb, _, _} = run([base: 15, jitter: 30, dup: 0.3, seed: 9], 12_345)
    for n <- @latency..(@ticks - 200), do: assert(frames[n] == expected(n - @latency))
    assert jb.stats.duplicate > 0
  end

  test "loss leaves silence exactly where packets were lost" do
    {frames, jb, dp, _} = run([base: 20, jitter: 40, loss: 0.1, seed: 3], 0)
    lost = dp.stats[:a].lost + dp.stats[:b].lost
    assert lost > 0

    silent =
      for n <- @latency..(@ticks - 200), s <- 0..2, reduce: 0 do
        acc ->
          got = Enum.at(frames[n], s)
          want = Enum.at(expected(n - @latency), s)
          assert got in [want, 0]
          if got == 0, do: acc + 1, else: acc
      end

    assert silent > 0 and silent <= jb.stats.underrun
  end

  test "jitter beyond the latency budget shows up as late writes and underruns" do
    {_, jb, _, _} = run([base: 100, jitter: 150, seed: 2], 0)
    assert jb.stats.late > 0 and jb.stats.underrun > 0
  end

  test "receiver clock skew shifts the playout by the skew" do
    # receiver reads 5 frames later in media time: frame n shows source n - latency + 5
    {frames, _, _, _} = run([base: 20, jitter: 10, seed: 4], 0, 5)
    for n <- @latency..(@ticks - 200), do: assert(frames[n] == expected(n - @latency + 5))
  end
end
