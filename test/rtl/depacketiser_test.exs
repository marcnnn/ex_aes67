defmodule ExAes67.RTL.DepacketiserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise
  alias ExAes67.{RTP, RTLDepack, RTLDrv}
  alias ExAes67.RTP.Payload
  alias ExAes67.RTL.Program

  @ips [{239, 1, 1, 1}, {239, 1, 1, 2}, {239, 1, 2, 9}]
  @ports [5004, 5005, 6000]

  defp entries_gen do
    entry =
      gen all(
            ip <- member_of(@ips),
            port <- member_of(@ports),
            pt <- member_of([96, 97, 98]),
            ssrc <- member_of([nil, 1, 2]),
            ch <- integer(1..4),
            base <- integer(0..40),
            fmt <- member_of([:l16, :l24])
          ) do
        %{
          dst_ip: ip,
          dst_port: port,
          pt: pt,
          ssrc: ssrc,
          channels: ch,
          base_channel: base,
          format: fmt
        }
      end

    gen all(es <- list_of(entry, min_length: 1, max_length: 6)) do
      es |> Enum.with_index() |> Enum.map(fn {e, i} -> Map.put(e, :id, i) end)
    end
  end

  defp sample(:l16), do: integer(-32768..32767)
  defp sample(:l24), do: integer(-8_388_608..8_388_607)

  defp packet_gen(entries) do
    one_of([
      valid_gen(entries),
      valid_gen(entries),
      valid_gen(entries),
      bad_gen(entries)
    ])
  end

  defp valid_gen(entries) do
    gen all(
          e <- member_of(entries),
          frames <- integer(0..9),
          seq <- one_of([integer(0..5), integer(65_530..65_535)]),
          ts <- one_of([integer(0..100_000), integer(0xFFFFFFF0..0xFFFFFFFF)]),
          ssrc <- member_of([1, 2, 3]),
          samples <- list_of(sample(e.format), length: frames * e.channels)
        ) do
      ssrc = if e.ssrc, do: e.ssrc, else: ssrc
      frames = samples |> Enum.chunk_every(e.channels)
      pkt = %RTP{pt: e.pt, seq: seq, ts: ts, ssrc: ssrc, payload: Payload.pack(e.format, frames)}
      {e.dst_ip, e.dst_port, RTP.encode(pkt)}
    end
  end

  defp bad_gen(entries) do
    gen all(
          {ip, port, bin} <- valid_gen(entries),
          kind <- member_of([:ip, :port, :pt, :ssrc, :short, :version, :extra]),
          n <- integer(1..11)
        ) do
      case kind do
        :ip ->
          {{10, 0, 0, 1}, port, bin}

        :port ->
          {ip, 9, bin}

        :pt ->
          {ip, port, <<0x80, 0x7F>> <> binary_part(bin, 2, byte_size(bin) - 2)}

        :ssrc ->
          {ip, port,
           binary_part(bin, 0, 8) <>
             <<0xDEADBEEF::32>> <> binary_part(bin, 12, byte_size(bin) - 12)}

        :short ->
          {ip, port, binary_part(bin, 0, min(n, byte_size(bin)))}

        :version ->
          {ip, port, <<0x40>> <> binary_part(bin, 1, byte_size(bin) - 1)}

        :extra ->
          {ip, port, bin <> :binary.copy(<<7>>, n)}
      end
    end
  end

  defp check_run(entries, packets, opts) do
    r = RTLDepack.run(entries, packets, opts)
    assert r.writes == r.model_writes

    for e <- entries do
      m = r.model.stats[e.id]
      assert r.stats[e.id] == Map.take(m, [:packets, :samples, :lost, :reordered])
    end

    ok = Enum.count(r.results, &match?({:ok, _}, &1))
    assert r.globals.ok == ok
    assert r.globals.no_stream == r.model.drops.no_stream
    assert r.globals.bad_length == r.model.drops.bad_length
    r
  end

  describe "against the model" do
    property "random tables and packets, colliding hash buckets" do
      check all(
              entries <- entries_gen(),
              packets <- list_of(packet_gen(entries), min_length: 1, max_length: 12),
              ready <- member_of([100, 50]),
              hb <- member_of([2, 3, 10]),
              max_runs: 25
            ) do
        check_run(entries, packets, ready: ready, hash_bits: hb, streams: 8, idle: 3, seed: 5)
      end
    end

    test "back to back packets with a stalled sink keep order and lose nothing" do
      e = %{
        id: :a,
        dst_ip: {239, 1, 1, 1},
        dst_port: 5004,
        ssrc: nil,
        pt: 97,
        channels: 3,
        base_channel: 0,
        format: :l24
      }

      packets =
        for i <- 0..15 do
          frames = for f <- 0..5, do: for(c <- 0..2, do: i * 100 + f * 3 + c - 800)

          {e.dst_ip, e.dst_port,
           RTP.encode(%RTP{
             pt: 97,
             seq: i,
             ts: i * 6,
             ssrc: 1,
             payload: Payload.pack(:l24, frames)
           })}
        end

      r = check_run([e], packets, ready: 30, streams: 8, hash_bits: 3, seed: 2)
      assert length(r.writes) == 16 * 18
      assert r.stats[:a].packets == 16 and r.stats[:a].lost == 0
    end

    test "CSRC, extension and padding packets are bad_rtp, everything else unaffected" do
      e = %{
        id: :a,
        dst_ip: {239, 1, 1, 1},
        dst_port: 5004,
        ssrc: nil,
        pt: 97,
        channels: 1,
        base_channel: 0,
        format: :l24
      }

      pay = Payload.pack(:l24, [[1], [2]])
      plain = RTP.encode(%RTP{pt: 97, seq: 1, ts: 0, ssrc: 1, payload: pay})
      pad = RTP.encode(%RTP{pt: 97, seq: 2, ts: 2, ssrc: 1, payload: pay, padding: 4})
      csrc = RTP.encode(%RTP{pt: 97, seq: 3, ts: 4, ssrc: 1, payload: pay, csrc: [7]})

      r =
        RTLDepack.run([e], for(p <- [plain, pad, csrc, plain], do: {e.dst_ip, e.dst_port, p}),
          streams: 8
        )

      assert r.globals == %{ok: 2, bad_rtp: 2, no_stream: 0, bad_length: 0}
      assert length(r.writes) == 4
    end

    test "packets over the bank size count as bad_length and do not corrupt the next one" do
      e = %{
        id: :a,
        dst_ip: {239, 1, 1, 1},
        dst_port: 5004,
        ssrc: nil,
        pt: 97,
        channels: 1,
        base_channel: 0,
        format: :l16
      }

      big =
        RTP.encode(%RTP{
          pt: 97,
          seq: 1,
          ts: 0,
          ssrc: 1,
          payload: Payload.pack(:l16, for(i <- 1..100, do: [i]))
        })

      small =
        RTP.encode(%RTP{
          pt: 97,
          seq: 2,
          ts: 100,
          ssrc: 1,
          payload: Payload.pack(:l16, [[5], [6]])
        })

      r =
        RTLDepack.run([e], [{e.dst_ip, e.dst_port, big}, {e.dst_ip, e.dst_port, small}],
          streams: 8,
          bank_words: 16
        )

      assert r.globals.bad_length == 1 and r.globals.ok == 1
      assert r.writes == [{0, 100, 1280}, {0, 101, 1536}]
    end
  end

  describe "program" do
    test "hash matches the RTL fold for every bucket width" do
      for hb <- 1..16, ip <- @ips, port <- @ports do
        assert Program.hash(ip, port, hb) in 0..((1 <<< hb) - 1)
      end
    end
  end

  @tag :verilator
  @tag timeout: 300_000
  test "Verilator reproduces the BEAM simulation" do
    entries = [
      %{
        id: 0,
        dst_ip: {239, 1, 1, 1},
        dst_port: 5004,
        ssrc: nil,
        pt: 97,
        channels: 2,
        base_channel: 3,
        format: :l24
      },
      %{
        id: 1,
        dst_ip: {239, 1, 1, 1},
        dst_port: 5004,
        ssrc: 7,
        pt: 98,
        channels: 1,
        base_channel: 9,
        format: :l16
      }
    ]

    mk = fn pt, seq, fmt, frames ->
      {{239, 1, 1, 1}, 5004,
       RTP.encode(%RTP{
         pt: pt,
         seq: seq,
         ts: seq * 10,
         ssrc: 7,
         payload: Payload.pack(fmt, frames)
       })}
    end

    packets = [
      mk.(97, 1, :l24, [[1, -2], [3, 4], [5, 6]]),
      mk.(98, 2, :l16, [[1], [2], [3]]),
      mk.(97, 5, :l24, [[100, 200]]),
      mk.(99, 6, :l24, [[1, 2]]),
      mk.(97, 4, :l24, [[7, 8]]),
      {{239, 1, 1, 1}, 5004, <<1, 2, 3>>}
    ]

    r = check_run(entries, packets, ready: 60, hash_bits: 2, streams: 8, idle: 2, seed: 9)
    assert RTLDrv.cosim(r.drv) == :ok
  end
end
