defmodule ExAes67.RTPTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise
  alias ExAes67.{RTCP, RTP}
  alias ExAes67.RTP.Payload

  test "fixed header bytes" do
    p = %RTP{pt: 97, seq: 7, ts: 1000, ssrc: 0xCAFE, marker: true, payload: <<9>>}
    assert RTP.encode(p) == <<0x80, 0x80 + 97, 0, 7, 0, 0, 3, 232, 0, 0, 0xCA, 0xFE, 9>>
  end

  test "csrc, extension and padding" do
    p = %RTP{
      pt: 96,
      seq: 1,
      ts: 2,
      ssrc: 3,
      csrc: [10, 20],
      ext: {0xBEDE, <<1, 2, 3, 4, 5, 6, 7, 8>>},
      payload: <<1, 2, 3>>,
      padding: 5
    }

    bin = RTP.encode(p)
    assert <<0b10110010, _::binary>> = bin
    assert byte_size(bin) == 12 + 8 + 4 + 8 + 3 + 5
    assert :binary.last(bin) == 5
    assert {:ok, ^p} = RTP.decode(bin)
  end

  test "malformed packets" do
    assert {:error, :bad_version} = RTP.decode(<<0x40, 0, 0, 0, 0::64, 0::32>>)
    assert {:error, :truncated} = RTP.decode(<<0x80, 0, 0>>)
    assert {:error, :truncated} = RTP.decode(<<0x82, 0, 0, 0, 0::64, 0::32>>)
    assert {:error, :truncated} = RTP.decode(<<0x90, 0, 0, 0, 0::64, 1::16>>)
    assert {:error, :truncated} = RTP.decode(<<0x90, 0, 0, 0, 0::64, 1::16, 5::16, 0::32>>)
    assert {:error, :bad_padding} = RTP.decode(<<0xA0, 0, 0, 0, 0::64, 9>>)
    assert {:error, :bad_padding} = RTP.decode(<<0xA0, 0, 0, 0, 0::64, 0>>)
    assert {:error, :bad_padding} = RTP.decode(<<0xA0, 0, 0, 0, 0::64>>)
  end

  test "wraparound arithmetic" do
    assert RTP.seq_add(65_535, 1) == 0
    assert RTP.seq_diff(0, 65_535) == 1
    assert RTP.seq_diff(65_535, 0) == -1
    assert RTP.seq_diff(32_768, 0) == -32_768
    assert RTP.ts_add(0xFFFFFFFF, 2) == 1
    assert RTP.ts_diff(5, 0xFFFFFFFB) == 10
    assert RTP.ts_diff(0xFFFFFFFB, 5) == -10
    assert RTP.seq_extend(65_535, 0) == 65_536
    assert RTP.seq_extend(65_536, 65_535) == 65_535
  end

  property "ts_add and ts_diff are inverse for small steps" do
    check all a <- integer(0..0xFFFFFFFF), n <- integer(-100_000..100_000) do
      assert RTP.ts_diff(RTP.ts_add(a, n), a) == n
    end
  end

  property "seq_extend tracks a monotone counter" do
    check all start <- integer(0..200_000), steps <- list_of(integer(0..1000), max_length: 50) do
      {last, ok?} =
        Enum.reduce(steps, {start, true}, fn d, {ext, ok} ->
          next = ext + d

          {RTP.seq_extend(ext, next &&& 0xFFFF),
           ok and RTP.seq_extend(ext, next &&& 0xFFFF) == next}
        end)

      assert ok?
      assert last >= start
    end
  end

  defp packet_gen do
    gen all pt <- integer(0..127),
            seq <- integer(0..65_535),
            ts <- integer(0..0xFFFFFFFF),
            ssrc <- integer(0..0xFFFFFFFF),
            marker <- boolean(),
            csrc <- list_of(integer(0..0xFFFFFFFF), max_length: 15),
            ext <- one_of([constant(nil), tuple({integer(0..65_535), binary(length: 8)})]),
            payload <- binary(max_length: 100),
            padding <- one_of([constant(0), integer(1..255)]) do
      %RTP{
        pt: pt,
        seq: seq,
        ts: ts,
        ssrc: ssrc,
        marker: marker,
        csrc: csrc,
        ext: ext,
        payload: payload,
        padding: padding
      }
    end
  end

  property "RTP round trip" do
    check all p <- packet_gen() do
      assert {:ok, p} == RTP.decode(RTP.encode(p))
    end
  end

  property "payload round trip" do
    check all ch <- integer(1..8),
              fmt <- member_of([:l16, :l24]),
              n <- integer(0..20) do
      bits = if fmt == :l16, do: 15, else: 23

      frames =
        for _ <- 1..n//1,
            do: for(_ <- 1..ch, do: :rand.uniform(1 <<< (bits + 1)) - 1 - (1 <<< bits))

      bin = Payload.pack(fmt, frames)
      assert byte_size(bin) == n * ch * Payload.bytes_per_sample(fmt)
      assert {:ok, frames} == Payload.unpack(fmt, bin, ch)
    end
  end

  test "payload edge cases" do
    assert Payload.pack(:l16, [[-32_768, 32_767]]) == <<0x80, 0, 0x7F, 0xFF>>
    assert Payload.pack(:l24, [[-8_388_608]]) == <<0x80, 0, 0>>
    assert {:error, :bad_length} = Payload.unpack(:l24, <<1, 2, 3, 4>>, 1)
    assert {:error, :bad_length} = Payload.unpack(:l16, <<1, 2, 3, 4>>, 3)
    assert Payload.to24(:l16, -1) == -256
    assert Payload.from24(:l16, -1) == -1
    assert Payload.from24(:l16, 255) == 0
  end

  test "RTCP SR/RR/SDES/BYE compound" do
    report = %{
      ssrc: 2,
      fraction_lost: 12,
      lost: -3,
      highest_seq: 70_000,
      jitter: 44,
      lsr: 5,
      dlsr: 6
    }

    sr = %{
      type: :sr,
      ssrc: 1,
      ntp: RTCP.ntp_from_unix_us(1_700_000_000_123_456),
      rtp_ts: 99,
      packets: 10,
      octets: 1440,
      reports: [report]
    }

    pkts = [
      sr,
      %{type: :sdes, chunks: [{1, [{:cname, "a@b"}, {:tool, "ex"}]}, {7, [{:cname, "abcd"}]}]},
      %{type: :rr, ssrc: 3, reports: [report, report]},
      %{type: :bye, ssrcs: [1, 3], reason: "done"}
    ]

    bin = RTCP.encode(pkts)
    assert rem(byte_size(bin), 4) == 0
    assert {:ok, ^pkts} = RTCP.decode(bin)
  end

  test "RTCP known SR bytes and errors" do
    bin =
      RTCP.encode([
        %{type: :sr, ssrc: 1, ntp: {2, 3}, rtp_ts: 4, packets: 5, octets: 6, reports: []}
      ])

    assert bin == <<0x80, 200, 0, 6, 1::32, 2::32, 3::32, 4::32, 5::32, 6::32>>
    assert {:error, :truncated} = RTCP.decode(binary_part(bin, 0, 10))
    assert {:error, :bad_version} = RTCP.decode(<<0x40, 200, 0, 0>>)

    assert {:ok, [%{type: :unknown, pt: 204, count: 1, body: <<0, 0, 0, 1, "ABCD">>}]} =
             RTCP.decode(<<0x81, 204, 0, 2, 1::32, "ABCD">>)

    assert RTCP.ntp_from_unix_us(0) == {2_208_988_800, 0}
    assert RTCP.ntp_from_unix_us(500_000) == {2_208_988_800, 2_147_483_648}
  end
end
