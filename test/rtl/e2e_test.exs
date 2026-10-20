defmodule ExAes67.RTL.E2ETest do
  @moduledoc """
  RTL packetiser -> simulated network (reorder, loss, duplicates) -> RTL
  depacketiser -> RTL jitter buffer, the same scenarios as `ExAes67.E2ETest`.
  The receive path is also run through the models with the same arrivals and
  must agree frame for frame and counter for counter.
  """
  use ExUnit.Case, async: true
  import Bitwise
  alias ExAes67.{RTLDrv, RTLPack, RTLRx, TestNet}

  @latency 128
  @ticks 460
  @check 128..260

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

  defp sample(0, t), do: 1 + rem(t * 7919, 8_000_000)
  defp sample(1, t), do: -1 - rem(t * 104_729, 8_000_000)
  defp sample(2, t), do: (1 + rem(t, 30_000)) * 256
  defp expected(t), do: [sample(0, t), sample(1, t), sample(2, t)]

  defp run(net_opts, offset, skew \\ 0) do
    tx =
      RTLPack.run(tx_cfgs(offset), &sample/2,
        channels: 3,
        ticks: @ticks,
        period: 250,
        depth: 128,
        now: 0
      )

    assert tx.stats.sched_overrun == 0 and tx.stats.late == 0 and tx.stats.silence == 0
    # the model packetiser agrees on what went out
    assert Enum.map(tx.rtl, &elem(&1, 1)) == Enum.map(tx.model, fn {_, p} -> p.udp_payload end)

    sent =
      for {t, bytes, user} <- tx.rtl do
        {t, %{dst_ip: ip_of(user), dst_port: user >>> 32 &&& 0xFFFF, udp_payload: bytes}}
      end

    arrivals =
      sent
      |> TestNet.deliver(net_opts)
      |> Enum.group_by(&elem(&1, 0), fn {_, p} -> {p.dst_ip, p.dst_port, p.udp_payload} end)

    opts = [latency: @latency, depth: 256, channels: 3]
    rtp0 = offset + skew
    rtl = RTLRx.run_rtl(rx_table(), arrivals, @ticks - 60, rtp0, opts)
    mdl = RTLRx.run_model(rx_table(), arrivals, @ticks - 60, rtp0, opts)

    assert rtl.frames == mdl.frames
    assert Map.delete(rtl.jb_stats, :tick_overrun) == mdl.jb_stats
    for id <- [:a, :b], do: assert(rtl.dp_stats[id] == Map.delete(mdl.dp_stats[id], :expected))
    {rtl, sent}
  end

  defp ip_of(user),
    do: {user >>> 24 &&& 255, user >>> 16 &&& 255, user >>> 8 &&& 255, user &&& 255}

  test "clean network with reordering jitter: original samples at the right media time" do
    {r, _} = run([base: 20, jitter: 40, seed: 1], 0)
    for n <- @check, do: assert(r.frames[n] == expected(n - @latency), "tick #{n}")
    assert r.jb_stats.late == 0 and r.jb_stats.overrun == 0 and r.jb_stats.duplicate == 0
    assert r.dp_stats[:a].reordered > 0 or r.dp_stats[:b].reordered > 0
  end

  test "RTP timestamp and sequence wraparound (mediaclk offset near 2^32)" do
    {r, sent} = run([base: 10, jitter: 60, seed: 5], 0xFFFFFF00)
    for n <- @check, do: assert(r.frames[n] == expected(n - @latency), "tick #{n}")
    assert r.jb_stats.late == 0

    assert Enum.any?(sent, fn {_, p} ->
             p.dst_port == 6000 and match?(<<_, _, 0, _, _::binary>>, p.udp_payload)
           end)
  end

  test "duplicates are absorbed" do
    {r, _} = run([base: 15, jitter: 30, dup: 0.3, seed: 9], 12_345)
    for n <- @check, do: assert(r.frames[n] == expected(n - @latency))
    assert r.jb_stats.duplicate > 0
  end

  test "loss leaves silence exactly where packets were lost" do
    {r, _} = run([base: 20, jitter: 40, loss: 0.1, seed: 3], 0)
    assert r.dp_stats[:a].lost + r.dp_stats[:b].lost > 0

    silent =
      for n <- @check, s <- 0..2, reduce: 0 do
        acc ->
          got = Enum.at(r.frames[n], s)
          want = Enum.at(expected(n - @latency), s)
          assert got in [want, 0]
          if got == 0, do: acc + 1, else: acc
      end

    assert silent > 0 and silent <= r.jb_stats.underrun
  end

  test "jitter beyond the latency budget shows up as late writes and underruns" do
    {r, _} = run([base: 100, jitter: 150, seed: 2], 0)
    assert r.jb_stats.late > 0 and r.jb_stats.underrun > 0
  end

  test "receiver clock skew shifts the playout by the skew" do
    {r, _} = run([base: 20, jitter: 10, seed: 4], 0, 5)
    for n <- @check, do: assert(r.frames[n] == expected(n - @latency + 5))
  end

  @tag :verilator
  @tag timeout: 600_000
  test "Verilator reproduces the receive path of a lossy, reordering run" do
    {r, _} = run([base: 20, jitter: 40, loss: 0.05, dup: 0.1, seed: 11], 777)
    assert RTLDrv.cosim(r.drv) == :ok
  end
end
