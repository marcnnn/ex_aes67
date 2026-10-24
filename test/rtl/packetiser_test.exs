defmodule ExAes67.RTL.PacketiserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias ExAes67.{RTLDrv, RTLPack}

  defp cfg_gen(i, base) do
    gen all(
          ch <- integer(1..3),
          ptime <- member_of([125, 250, 500, 1000]),
          fmt <- member_of([:l16, :l24]),
          offset <- one_of([integer(0..1000), integer(0xFFFFFF00..0xFFFFFFFF)]),
          seq0 <- one_of([integer(0..10), integer(65_530..65_535)]),
          ssrc <- integer(1..0xFFFFFFFF)
        ) do
      %{
        id: i,
        channels: ch,
        base_channel: base,
        ptime_us: ptime,
        format: fmt,
        pt: 96 + i,
        ssrc: ssrc,
        dst_ip: {239, 1, 1, 1 + i},
        dst_port: 5004 + i,
        ts_offset: offset,
        seq0: seq0
      }
    end
  end

  defp cfgs_gen do
    gen all(n <- integer(1..4), chs <- list_of(integer(1..3), length: n)) do
      {cfgs, _} =
        Enum.map_reduce(Enum.with_index(chs), 0, fn {ch, i}, base ->
          {{i, ch, base}, base + ch}
        end)

      cfgs
    end
    |> bind(fn specs ->
      specs
      |> Enum.map(fn {i, ch, base} -> cfg_gen(i, base) |> map(&%{&1 | channels: ch}) end)
      |> fixed_list()
    end)
  end

  defp sample(c, t), do: rem(t * 7919 + c * 104_729, 16_000_000) - 8_000_000

  defp compare(cfgs, sample, opts) do
    nch = cfgs |> Enum.map(&(&1.base_channel + &1.channels)) |> Enum.max()
    r = RTLPack.run(cfgs, sample, [channels: nch, period: 400] ++ opts)
    assert length(r.rtl) == length(r.model)

    for {{t, bytes, user}, {mt, p}} <- Enum.zip(r.rtl, r.model) do
      assert t == mt
      assert bytes == p.udp_payload
      cfg = Enum.find(cfgs, &(&1.id == p.stream))
      ip = cfg.dst_ip |> Tuple.to_list() |> Enum.reduce(0, &(Bitwise.bsl(&2, 8) + &1))
      assert user == ip + Bitwise.bsl(cfg.dst_port, 32) + Bitwise.bsl(byte_size(bytes), 48)
    end

    assert r.stats.packets == length(r.model)
    assert r.stats.silence == r.model_stats.silence
    assert r.stats.sched_overrun == 0 and r.stats.late == 0
    r
  end

  property "packets are bit identical to the model, in order and in the same tick" do
    check all(
            cfgs <- cfgs_gen(),
            ready <- member_of([100, 60]),
            now <- member_of([0, 7, 1000]),
            max_runs: 10
          ) do
      compare(cfgs, &sample/2, ticks: 70, ready: ready, now: now, depth: 64)
    end
  end

  test "skipped ring writes are silence and counted like the model" do
    cfgs = [
      %{
        id: 0,
        channels: 2,
        base_channel: 0,
        ptime_us: 250,
        format: :l24,
        pt: 97,
        ssrc: 1,
        dst_ip: {239, 1, 1, 1},
        dst_port: 5004
      }
    ]

    skip = fn c, t -> if rem(t * 7 + c * 3, 11) == 0, do: nil, else: sample(c, t) end
    r = compare(cfgs, skip, ticks: 60, depth: 32)

    assert r.stats.silence > 0
    assert r.stats.silence == r.model_stats.silence
  end

  @tag :verilator
  @tag timeout: 300_000
  test "Verilator reproduces the BEAM simulation" do
    cfgs = [
      %{
        id: 0,
        channels: 2,
        base_channel: 0,
        ptime_us: 250,
        format: :l24,
        pt: 97,
        ssrc: 0xA,
        dst_ip: {239, 1, 1, 1},
        dst_port: 5004,
        ts_offset: 99,
        seq0: 65535
      },
      %{
        id: 1,
        channels: 1,
        base_channel: 2,
        ptime_us: 125,
        format: :l16,
        pt: 98,
        ssrc: 0xB,
        dst_ip: {239, 1, 1, 2},
        dst_port: 6000
      }
    ]

    r = compare(cfgs, &sample/2, ticks: 30, ready: 70, depth: 32, seed: 4)
    assert RTLDrv.cosim(r.drv) == :ok
  end

  test "configuration written slower than a packet period never sends a half written stream" do
    alias ExAes67.RTL.{Packetiser, Program}
    import Bitwise

    cfg = %{
      id: :out,
      channels: 4,
      base_channel: 0,
      ptime_us: 125,
      format: :l24,
      pt: 98,
      ssrc: 0xA67,
      dst_ip: {239, 69, 2, 1},
      dst_port: 5004
    }

    now = 48_000_600
    d = RTLDrv.new(Packetiser.build(streams: 4, channels: 8, depth: 16))
    d = RTLDrv.set(d, %{m_axis_tready: 1})

    # one media tick between consecutive writes, as over AXI4-Lite and a clock crossing
    {d, t, users} =
      Enum.reduce(Program.tx([cfg], now), {d, now, []}, fn w, {d, t, us} ->
        d = d |> RTLDrv.set(w) |> RTLDrv.step() |> RTLDrv.set(%{cfg_we: 0})
        d = d |> RTLDrv.set(%{tick: 1, rtp_ts: t &&& 0xFFFFFFFF}) |> RTLDrv.step()
        d = RTLDrv.set(d, %{tick: 0})

        {d, us} =
          Enum.reduce(1..60, {d, us}, fn _, {d, us} ->
            us =
              if RTLDrv.peek(d, :m_axis_tvalid) == 1 and RTLDrv.peek(d, :m_axis_tlast) == 1,
                do: [RTLDrv.peek(d, :m_axis_tuser) >>> 48 | us],
                else: us

            {RTLDrv.step(d), us}
          end)

        {d, t + 1, us}
      end)

    {_d, users} =
      Enum.reduce(t..(t + 20), {d, users}, fn t, {d, us} ->
        d = d |> RTLDrv.set(%{tick: 1, rtp_ts: t}) |> RTLDrv.step() |> RTLDrv.set(%{tick: 0})

        Enum.reduce(1..60, {d, us}, fn _, {d, us} ->
          us =
            if RTLDrv.peek(d, :m_axis_tvalid) == 1 and RTLDrv.peek(d, :m_axis_tlast) == 1,
              do: [RTLDrv.peek(d, :m_axis_tuser) >>> 48 | us],
              else: us

          {RTLDrv.step(d), us}
        end)
      end)

    # 6 samples x 4 channels x 3 bytes + 12 byte RTP header
    assert users != [] and Enum.all?(users, &(&1 == 84))
  end
end
