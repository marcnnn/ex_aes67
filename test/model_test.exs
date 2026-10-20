defmodule ExAes67.ModelTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise
  alias ExAes67.{LinkBudget, RTP}
  alias ExAes67.Model.{Depacketiser, JitterBuffer, Packetiser, SampleRing}
  alias ExAes67.RTP.Payload

  describe "jitter buffer" do
    defp jb(opts \\ []),
      do: JitterBuffer.new([depth: 16, channels: 2, latency: 8, now: 100] ++ opts)

    defp write_frame(jb, ts, v) do
      Enum.reduce(0..1, jb, fn ch, jb -> elem(JitterBuffer.write(jb, ch, ts, v + ch), 0) end)
    end

    test "plays frames at media time minus latency, in order" do
      b = Enum.reduce(92..107, jb(), &write_frame(&2, &1, &1 * 10))

      {outs, b} =
        Enum.map_reduce(100..110, b, fn now, b ->
          {b, f} = JitterBuffer.play(b, now)
          {{now, f}, b}
        end)

      assert outs == for(now <- 100..110, do: {now, [(now - 8) * 10, (now - 8) * 10 + 1]})
      assert b.stats.played == 11 and b.stats.underrun == 0 and b.stats.written == 32
    end

    test "underrun yields silence and is counted per channel; stale data is not replayed" do
      b = jb()
      {b, [0, 0]} = JitterBuffer.play(b, 100)
      assert b.stats.underrun == 2
      # the slot of ts 100 still holds ts 100: must not be played as ts 116
      b = write_frame(b, 100, 5)
      {b, [0, 0]} = JitterBuffer.play(b, 124)
      assert b.stats.underrun == 4
      {b, r} = JitterBuffer.write(b, 0, 122, 1)
      assert r == :ok and b.stats.written == 3
    end

    test "late, overrun, duplicate and bad channel" do
      b = jb()
      assert {b, :late} = JitterBuffer.write(b, 0, 91, 1)
      assert {b, :ok} = JitterBuffer.write(b, 0, 92, 1)
      assert {b, :ok} = JitterBuffer.write(b, 0, 107, 1)
      assert {b, :overrun} = JitterBuffer.write(b, 0, 108, 1)
      assert {b, :duplicate} = JitterBuffer.write(b, 0, 92, 99)
      assert {b, :bad_channel} = JitterBuffer.write(b, 2, 92, 1)
      assert {b, :bad_channel} = JitterBuffer.write(b, -1, 92, 1)

      assert Map.take(b.stats, [:late, :overrun, :duplicate, :bad_channel, :written]) ==
               %{late: 1, overrun: 1, duplicate: 1, bad_channel: 2, written: 2}

      # first copy wins
      {_, [1, 0]} = JitterBuffer.play(%{b | next: 92}, 100)
    end

    test "late after playout" do
      {b, _} = JitterBuffer.play(jb(), 100)
      assert {_, :late} = JitterBuffer.write(b, 0, 92, 1)
      assert {_, :ok} = JitterBuffer.write(b, 0, 93, 1)
    end

    test "depth must be a power of two above latency" do
      for opts <- [[depth: 12, latency: 4], [depth: 8, latency: 8], [depth: 0, latency: 0]] do
        assert_raise ArgumentError, fn -> JitterBuffer.new([channels: 1] ++ opts) end
      end
    end

    test "timestamp wraparound" do
      start = 0xFFFFFFF0
      b = JitterBuffer.new(depth: 16, channels: 1, latency: 4, now: start)

      {outs, _} =
        Enum.map_reduce(0..30, b, fn i, b ->
          # frames arrive 3 ticks ahead of their playout
          {b, :ok} = JitterBuffer.write(b, 0, start - 4 + i + 3 &&& 0xFFFFFFFF, i + 4)
          {b, [s]} = JitterBuffer.play(b, start + i &&& 0xFFFFFFFF)
          {s, b}
        end)

      assert Enum.drop(outs, 3) == Enum.to_list(4..31)
    end

    property "any arrival order inside the window plays the same frames" do
      check all keys <- list_of(integer(0..1_000_000), length: 10) do
        order = Enum.sort_by(0..9, &Enum.at(keys, &1))
        b = JitterBuffer.new(depth: 16, channels: 1, latency: 10, now: 10)
        b = Enum.reduce(order, b, fn t, b -> elem(JitterBuffer.write(b, 0, t, t + 1000), 0) end)

        {outs, _} =
          Enum.map_reduce(10..19, b, fn now, b ->
            {b, [s]} = JitterBuffer.play(b, now)
            {s, b}
          end)

        assert outs == Enum.map(0..9, &(&1 + 1000))
      end
    end

    test "receiver clock ahead of the sender eats into the latency margin" do
      # frame t reaches the receiver 6 ticks after it was sent; a receiver clock
      # d ticks ahead sees it at t + 6 + d but still plays it at t + 8
      underruns = fn d ->
        {b, mid} =
          Enum.reduce(
            0..60,
            {JitterBuffer.new(depth: 32, channels: 1, latency: 8, now: 0), nil},
            fn now, {b, mid} ->
              b =
                if now - 6 - d >= 0,
                  do: elem(JitterBuffer.write(b, 0, now - 6 - d, 1), 0),
                  else: b

              {b, _} = JitterBuffer.play(b, now)
              {b, if(now == 20, do: b.stats.underrun, else: mid)}
            end
          )

        b.stats.underrun - mid
      end

      assert {underruns.(0), underruns.(2)} == {0, 0}
      assert underruns.(3) == 40
    end
  end

  describe "depacketiser" do
    @entries [
      %{
        id: :a,
        dst_ip: {239, 1, 1, 1},
        dst_port: 5004,
        ssrc: nil,
        pt: 97,
        channels: 2,
        base_channel: 10,
        format: :l24
      },
      %{
        id: :b,
        dst_ip: {239, 1, 1, 1},
        dst_port: 5004,
        ssrc: 0x42,
        pt: 98,
        channels: 1,
        base_channel: 20,
        format: :l16
      },
      %{
        id: :c,
        dst_ip: {239, 1, 1, 2},
        dst_port: 49_152,
        ssrc: 7,
        pt: 97,
        channels: 1,
        base_channel: 30,
        format: :l24
      }
    ]

    defp pkt(pt, seq, ts, ssrc, fmt, frames),
      do:
        RTP.encode(%RTP{pt: pt, seq: seq, ts: ts, ssrc: ssrc, payload: Payload.pack(fmt, frames)})

    test "lookup on ip, port, pt and ssrc; any port; L16 is left justified" do
      d = Depacketiser.new(@entries)

      {d, w, {:ok, :a}} =
        Depacketiser.process(d, {239, 1, 1, 1}, 5004, pkt(97, 0, 5, 1, :l24, [[1, 2]]))

      assert w == [{10, 5, 1}, {11, 5, 2}]

      {d, w, {:ok, :b}} =
        Depacketiser.process(d, {239, 1, 1, 1}, 5004, pkt(98, 0, 5, 0x42, :l16, [[-1], [2]]))

      assert w == [{20, 5, -256}, {20, 6, 512}]

      {d, _, {:ok, :c}} =
        Depacketiser.process(d, {239, 1, 1, 2}, 49_152, pkt(97, 0, 0, 7, :l24, [[1]]))

      assert d.stats[:c].packets == 1
    end

    test "drops are classified" do
      d = Depacketiser.new(@entries)
      p = pkt(97, 0, 0, 1, :l24, [[1, 2]])
      assert {d, [], {:drop, :no_stream}} = Depacketiser.process(d, {239, 1, 1, 9}, 5004, p)
      assert {d, [], {:drop, :no_stream}} = Depacketiser.process(d, {239, 1, 1, 1}, 5005, p)

      assert {d, [], {:drop, :no_stream}} =
               Depacketiser.process(d, {239, 1, 1, 2}, 49_152, pkt(97, 0, 0, 8, :l24, [[1]]))

      assert {d, [], {:drop, :no_stream}} =
               Depacketiser.process(d, {239, 1, 1, 1}, 5004, pkt(99, 0, 0, 1, :l24, [[1, 2]]))

      assert {d, [], {:drop, :bad_rtp}} =
               Depacketiser.process(d, {239, 1, 1, 1}, 5004, <<1, 2, 3>>)

      bad = RTP.encode(%RTP{pt: 97, payload: <<1, 2, 3, 4>>})
      assert {d, [], {:drop, :bad_length}} = Depacketiser.process(d, {239, 1, 1, 1}, 5004, bad)
      assert d.drops == %{no_stream: 4, bad_rtp: 1, bad_length: 1}
    end

    test "padding, csrc and extension are skipped; timestamps wrap" do
      d = Depacketiser.new(@entries)

      p =
        RTP.encode(%RTP{
          pt: 97,
          ts: 0xFFFFFFFF,
          csrc: [1, 2],
          ext: {1, <<0::32>>},
          padding: 3,
          payload: Payload.pack(:l24, [[1, 2], [3, 4]])
        })

      assert {_, [{10, 0xFFFFFFFF, 1}, {11, 0xFFFFFFFF, 2}, {10, 0, 3}, {11, 0, 4}], _} =
               Depacketiser.process(d, {239, 1, 1, 1}, 5004, p)
    end

    test "sequence statistics: loss, reorder, duplicate, wrap" do
      d = Depacketiser.new(@entries)

      d =
        Enum.reduce([65_534, 65_535, 0, 3, 2, 3, 4], d, fn seq, d ->
          elem(
            Depacketiser.process(d, {239, 1, 1, 1}, 5004, pkt(97, seq, 0, 1, :l24, [[1, 2]])),
            0
          )
        end)

      st = d.stats[:a]
      assert {st.packets, st.samples, st.lost, st.reordered} == {7, 14, 2, 2}
    end
  end

  describe "packetiser" do
    defp cfg(id, extra \\ %{}) do
      Map.merge(
        %{
          id: id,
          channels: 2,
          base_channel: 0,
          ptime_us: 1000,
          format: :l24,
          pt: 97,
          ssrc: 100 + id,
          dst_ip: {239, 1, 1, id},
          dst_port: 5004
        },
        extra
      )
    end

    defp filled_ring(n, channels \\ 8) do
      Enum.reduce(0..(n - 1), SampleRing.new(depth: 512), fn t, r ->
        Enum.reduce(0..(channels - 1), r, &SampleRing.write(&2, &1, t, t * 16 + &1))
      end)
    end

    test "packets are bit identical to the codec" do
      {p, pkts} = Packetiser.tick(Packetiser.new([cfg(1)]), filled_ring(200), 150)
      assert length(pkts) == 3
      [a, b | _] = pkts
      assert {a.rtp.seq, a.rtp.ts, b.rtp.seq, b.rtp.ts} == {0, 0, 1, 48}
      assert a.udp_payload == RTP.encode(a.rtp)
      frames = for t <- 0..47, do: [t * 16, t * 16 + 1]
      assert a.rtp.payload == Payload.pack(:l24, frames)
      assert {:ok, a.rtp} == RTP.decode(a.udp_payload)
      assert p.stats.packets == 3
    end

    test "L16 takes the top bits, pt/ssrc/offset applied, sequence and timestamp wrap" do
      c =
        cfg(1, %{
          format: :l16,
          pt: 101,
          ssrc: 0xDEADBEEF,
          seq0: 65_535,
          ts_offset: 0xFFFFFFF0,
          channels: 1
        })

      ring =
        Enum.reduce(0..199, SampleRing.new(depth: 512), &SampleRing.write(&2, 0, &1, 0x123456))

      {_, [a, b | _]} = Packetiser.tick(Packetiser.new([c]), ring, 150)
      assert {a.rtp.pt, a.rtp.ssrc, a.rtp.seq, a.rtp.ts} == {101, 0xDEADBEEF, 65_535, 0xFFFFFFF0}
      assert {b.rtp.seq, b.rtp.ts} == {0, 0xFFFFFFF0 + 48 - 0x100000000}
      assert binary_part(a.rtp.payload, 0, 2) == <<0x12, 0x34>>
    end

    test "ptime range and alignment" do
      for {us, spp} <- [{125, 6}, {250, 12}, {333, nil}, {500, 24}, {1000, 48}, {4000, 192}] do
        if spp do
          {_, [pkt]} =
            Packetiser.tick(
              Packetiser.new([cfg(1, %{ptime_us: us, channels: 1})]),
              filled_ring(200),
              spp
            )

          assert byte_size(pkt.rtp.payload) == spp * 3
        else
          assert_raise ArgumentError, fn -> Packetiser.new([cfg(1, %{ptime_us: us})]) end
        end
      end

      assert_raise ArgumentError, fn -> Packetiser.new([cfg(1, %{ptime_us: 100})]) end
      assert_raise ArgumentError, fn -> Packetiser.new([cfg(1, %{ptime_us: 4250})]) end

      assert_raise ArgumentError, fn ->
        Packetiser.new([cfg(1, %{ptime_us: 4000, channels: 8})])
      end
    end

    test "start aligns to the next packet boundary" do
      {_, [a, _]} = Packetiser.tick(Packetiser.new([cfg(1)], now: 50), filled_ring(400), 200)
      assert a.rtp.ts == 96
    end

    test "staggered schedule spreads packets over the interval" do
      cfgs = for i <- 0..7, do: cfg(i + 1, %{channels: 1, ptime_us: 125})
      ring = filled_ring(60, 1)

      {dues, _} =
        Enum.reduce(1..30, {[], Packetiser.new(cfgs)}, fn now, {acc, p} ->
          {p, pkts} = Packetiser.tick(p, ring, now)
          assert Enum.all?(pkts, &(&1.due == now))
          {acc ++ Enum.map(pkts, &{now, &1.stream}), p}
        end)

      first = for {now, id} <- dues, now <= 12, do: {now, id}
      # spp 6: stream index i fires at 6 + (i mod 6) and 12 + (i mod 6)
      assert Enum.sort(first) ==
               Enum.sort(
                 for(i <- 0..7, k <- [6, 12], k + rem(i, 6) <= 12, do: {k + rem(i, 6), i + 1})
               )

      assert dues |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() > 6
    end

    test "per-stream sequence numbers and stale ring slots send silence" do
      p = Packetiser.new([cfg(1), cfg(2, %{base_channel: 4})])
      {p, pkts} = Packetiser.tick(p, filled_ring(100, 3), 100)
      assert p.stats.silence > 0
      seqs = for s <- [1, 2], do: pkts |> Enum.filter(&(&1.stream == s)) |> Enum.map(& &1.rtp.seq)
      assert seqs == [[0, 1], [0, 1]]
      silent = Enum.find(pkts, &(&1.stream == 2))
      assert silent.rtp.payload == :binary.copy(<<0>>, 48 * 6)
    end

    test "oversubscription drops without consuming sequence numbers" do
      cfgs = for i <- 0..3, do: cfg(i + 1, %{channels: 1, ptime_us: 125})
      ring = filled_ring(40, 1)
      {p, pkts} = Packetiser.tick(Packetiser.new(cfgs, max_per_tick: 2), ring, 12)
      # five packets are due (starts 0 and 6 of stream 1, start 0 of the others)
      assert Enum.map(pkts, &{&1.stream, &1.rtp.seq}) == [{1, 0}, {2, 0}]
      assert p.stats.oversubscribed == 3

      # stream 1 lost its start-6 packet but keeps counting from seq 1 at start 12
      {_, pkts} = Packetiser.tick(%{p | max_per_tick: nil}, ring, 18)
      assert Enum.find(pkts, &(&1.stream == 1)).rtp |> then(&{&1.seq, &1.ts}) == {1, 12}
    end
  end

  describe "link budget" do
    test "matches the SCALING table at 1 Gbit/s, 1 ms, L24" do
      assert LinkBudget.table([1, 2, 4, 8], 1000, 1.0) == [
               {1, 563, 563},
               {2, 341, 682},
               {4, 191, 764},
               {8, 101, 808}
             ]

      assert LinkBudget.wire_bytes(2, 1000) == 366
      assert LinkBudget.wire_bytes(4, 1000) == 654
      assert LinkBudget.wire_bytes(8, 1000) == 1230
    end

    test "other ptimes, vlan, L16, headroom and 10G" do
      assert LinkBudget.payload_bytes(8, 125) == 144
      assert LinkBudget.wire_bytes(1, 125) == 8 + 14 + 20 + 8 + 12 + 18 + 4 + 12
      assert LinkBudget.wire_bytes(1, 1000, vlan: true) == 226
      assert LinkBudget.wire_bytes(1, 1000, format: :l16) == 54 + 96 + 24
      assert LinkBudget.streams_per_link(1, 1000, 1.0, headroom: 0.85) == 478
      assert LinkBudget.streams_per_link(1, 1000, 10.0) == 5630
      assert LinkBudget.packets_per_second(250) == 4000.0
      assert_in_delta LinkBudget.utilisation(563, 1, 1000, 1.0), 0.9999, 0.0001
      assert_raise ArgumentError, fn -> LinkBudget.frames_per_packet(333) end
    end
  end
end
