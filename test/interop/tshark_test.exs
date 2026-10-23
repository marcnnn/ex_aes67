defmodule ExAes67.Interop.TsharkTest do
  @moduledoc """
  Packets built by ex_aes67 (RTP L16/L24, RTCP SR/RR/SDES/BYE, SAP with an AES67 SDP,
  mDNS/DNS-SD, RTSP DESCRIBE) dissected by Wireshark's tshark in the `ex-interop-tshark`
  container: no malformed markers, no expert warnings, and every field equals what
  went in. The reverse direction decodes Wireshark sample captures (RTP L16, mDNS, RTSP)
  with ex_aes67 and compares with tshark's view.
  """
  use ExUnit.Case, async: false

  alias ExAes67.{DNS, RTCP, RTP, RTSP, SAP, SDP}
  alias ExAes67.RTP.Payload
  alias ExAes67.SDP.Stream
  alias Interop.{Captures, Frame, Tshark}

  @moduletag :interop
  @moduletag timeout: 300_000

  @gm <<0x39, 0xA7, 0x94, 0xFF, 0xFE, 0x07, 0xCB, 0xD0>>
  @tcp_prefs ["tcp.analyze_sequence_numbers:FALSE"]

  defp stream do
    %Stream{
      name: "Out 1-2",
      info: "two ch",
      origin_addr: "10.0.0.5",
      sess_id: "1311738121",
      sess_version: "1311738121",
      dest_ip: {239, 69, 0, 1},
      port: 5004,
      pt: 98,
      encoding: :l24,
      channels: 2,
      ptime: 1,
      ts_refclk: Stream.ptp_refclk(@gm, 0),
      mediaclk: {:direct, 0},
      direction: :sendonly
    }
  end

  defp media_udp(payload, port, opts \\ []) do
    Frame.udp(
      payload,
      [dst_ip: {239, 69, 0, 1}, dst_port: port, src_port: port, src_ip: {10, 0, 0, 5}] ++ opts
    )
  end

  defp hex(bin), do: bin |> Base.encode16(case: :lower) |> String.replace(~r/(..)(?=.)/, "\\1:")

  test "SAP announcement and deletion with an AES67 SDP" do
    sdp = Stream.generate(stream())
    ann = SAP.encode(%{type: :announce, msg_id: 0x1234, origin: {10, 0, 0, 5}, payload: sdp})
    del = SAP.encode(%{type: :delete, msg_id: 0x1234, origin: {10, 0, 0, 5}, payload: sdp})

    frames =
      for p <- [ann, del],
          do:
            Frame.udp(p,
              dst_ip: {239, 255, 255, 255},
              dst_port: 9875,
              src_port: 9875,
              src_ip: {10, 0, 0, 5},
              ttl: 255
            )

    pkts = Tshark.dissect(frames)
    Tshark.assert_clean(pkts)
    [a, d] = pkts

    assert Tshark.get(a, "sap.flags.v") == "1"
    assert Tshark.get(a, "sap.flags.t") == "0"
    assert Tshark.get(d, "sap.flags.t") == "1"

    for p <- pkts do
      assert Tshark.get(p, "sap.message_identifier_hash") == "0x1234"
      assert Tshark.get(p, "sap.originating_source") == "10.0.0.5"
      assert Tshark.get(p, "sap.payload_type") == "application/sdp"
    end

    assert Tshark.get(a, "sdp.session_name") == "Out 1-2"
    assert Tshark.get(a, "sdp.owner.address") == "10.0.0.5"
    assert Tshark.get(a, "sdp.owner.sessionid") == "1311738121"
    assert Tshark.get(a, "sdp.connection_info.address") == "239.69.0.1"
    assert Tshark.get(a, "sdp.connection_info.ttl") == "32"
    assert Tshark.get(a, "sdp.media.port") == "5004"
    assert Tshark.get(a, "sdp.media_title") == "two ch"
    assert Tshark.get(a, "sdp.mime.type") == "L24"
    assert Tshark.get(a, "sdp.sample_rate") == "48000"
    assert Tshark.get(a, "sdp.channels") == "2"
    attrs = Tshark.all(a, "sdp.media_attr")
    assert "ptime:1" in attrs
    assert "mediaclk:direct=0" in attrs
    assert "ts-refclk:ptp=IEEE1588-2008:39-A7-94-FF-FE-07-CB-D0:0" in attrs
    assert "sendonly" in attrs
  end

  test "RTP L24 and L16 (marker, wrap-around, CSRC) after an SDP announcement" do
    sdp = Stream.generate(stream())
    ann = SAP.encode(%{type: :announce, msg_id: 1, origin: {10, 0, 0, 5}, payload: sdp})

    l24 =
      Payload.pack(:l24, [[1, -1], [256, -256], [8_388_607, -8_388_608]])

    l16 = Payload.pack(:l16, [[1, -1], [256, -256], [32_767, -32_768]])

    pkts_in = [
      %RTP{pt: 98, seq: 65_535, ts: 0xFFFFFFF0, ssrc: 0xCAFEBABE, marker: true, payload: l24},
      %RTP{pt: 98, seq: 0, ts: 48, ssrc: 0xCAFEBABE, payload: l24},
      %RTP{pt: 10, seq: 5, ts: 480, ssrc: 0x1234, csrc: [7, 8], payload: l16},
      %RTP{pt: 98, seq: 9, ts: 9, ssrc: 3, ext: {0xBEDE, <<1, 2, 3, 4>>}, payload: l24},
      %RTP{pt: 98, seq: 10, ts: 10, ssrc: 3, padding: 4, payload: l24}
    ]

    frames =
      [
        Frame.udp(ann,
          dst_ip: {239, 255, 255, 255},
          dst_port: 9875,
          src_port: 9875,
          src_ip: {10, 0, 0, 5}
        )
        | Enum.map(pkts_in, &media_udp(RTP.encode(&1), 5004))
      ]

    [_sap | pkts] = out = Tshark.dissect(frames)
    Tshark.assert_clean(out)

    for {p, rtp} <- Enum.zip(pkts, pkts_in) do
      assert Tshark.get(p, "rtp.version") == "2"
      assert Tshark.get(p, "rtp.p_type") == "#{rtp.pt}"
      assert Tshark.get(p, "rtp.seq") == "#{rtp.seq}"
      assert Tshark.get(p, "rtp.timestamp") == "#{rtp.ts}"

      assert Tshark.get(p, "rtp.ssrc") ==
               "0x" <>
                 String.pad_leading(Integer.to_string(rtp.ssrc, 16) |> String.downcase(), 8, "0")

      assert Tshark.get(p, "rtp.marker") == if(rtp.marker, do: "1", else: "0")
      assert Tshark.get(p, "rtp.cc") == "#{length(rtp.csrc)}"
      assert Tshark.get(p, "rtp.ext") == if(rtp.ext, do: "1", else: "0")
      assert Tshark.get(p, "rtp.padding") == if(rtp.padding > 0, do: "1", else: "0")
      assert Tshark.get(p, "rtp.payload") == hex(rtp.payload)
    end

    # Wireshark learnt the payload type 98 mapping from the SDP in the SAP packet
    assert Tshark.get(Enum.at(pkts, 0), "rtp.setup-method") == "SDP"
    assert Tshark.all(Enum.at(pkts, 2), "rtp.csrc.item") == ["0x00000007", "0x00000008"]
    # extended sequence number: seq 65535 then 0 (cycle 1)
    assert Tshark.get(Enum.at(pkts, 1), "rtp.extseq") == "65536"
  end

  test "RTCP SR with a report block, SDES, RR and BYE" do
    sr =
      RTCP.encode([
        %{
          type: :sr,
          ssrc: 0xCAFEBABE,
          ntp: {3_900_000_000, 123_456},
          rtp_ts: 1000,
          packets: 10,
          octets: 1440,
          reports: [
            %{
              ssrc: 0x1234,
              fraction_lost: 5,
              lost: 3,
              highest_seq: 70_000,
              jitter: 12,
              lsr: 99,
              dlsr: 100
            }
          ]
        },
        %{type: :sdes, chunks: [{0xCAFEBABE, [{:cname, "ep@host"}, {:name, "Out"}]}]}
      ])

    bye =
      RTCP.encode([
        %{type: :rr, ssrc: 1, reports: []},
        %{type: :bye, ssrc: nil, ssrcs: [0xCAFEBABE], reason: "done"}
      ])

    pkts = Tshark.dissect([media_udp(sr, 5005), media_udp(bye, 5005)])
    Tshark.assert_clean(pkts)
    [p1, p2] = pkts

    assert Tshark.all(p1, "rtcp.pt") == ["200", "202"]
    assert Tshark.get(p1, "rtcp.senderssrc") == "0xcafebabe"
    assert Tshark.get(p1, "rtcp.timestamp.ntp.msw") == "3900000000"
    assert Tshark.get(p1, "rtcp.timestamp.ntp.lsw") == "123456"
    assert Tshark.get(p1, "rtcp.timestamp.rtp") == "1000"
    assert Tshark.get(p1, "rtcp.sender.packetcount") == "10"
    assert Tshark.get(p1, "rtcp.sender.octetcount") == "1440"

    assert Tshark.get(p1, "rtcp.ssrc.identifier") == "0x00001234" or
             "0x00001234" in Tshark.all(p1, "rtcp.ssrc.identifier")

    assert Tshark.get(p1, "rtcp.ssrc.fraction") == "5"
    assert Tshark.get(p1, "rtcp.ssrc.cum_nr") == "3"
    assert Tshark.get(p1, "rtcp.ssrc.ext_high") == "70000"
    assert Tshark.get(p1, "rtcp.ssrc.jitter") == "12"
    assert Tshark.get(p1, "rtcp.ssrc.lsr") == "99"
    assert Tshark.get(p1, "rtcp.ssrc.dlsr") == "100"
    assert Tshark.all(p1, "rtcp.sdes.text") == ["ep@host", "Out"]

    assert Tshark.all(p2, "rtcp.pt") == ["201", "203"]
    assert Tshark.get(p2, "rtcp.senderssrc") == "0x00000001"
    assert "0xcafebabe" in Tshark.all(p2, "rtcp.ssrc.identifier")
    assert Tshark.get(p2, "rtcp.sdes.text") == "done"
  end

  test "mDNS / DNS-SD query and response" do
    q =
      DNS.encode(%DNS.Message{
        questions: [DNS.question("_ravenna_session._sub._rtsp._tcp.local", :ptr, unicast: true)]
      })

    resp =
      DNS.encode(%DNS.Message{
        response: true,
        authoritative: true,
        answers: [
          DNS.record("_rtsp._tcp.local", :ptr, "Stage Box._rtsp._tcp.local", 4500),
          DNS.record("Stage Box._rtsp._tcp.local", :srv, {0, 0, 554, "stagebox.local"}, 120,
            cache_flush: true
          ),
          DNS.record("Stage Box._rtsp._tcp.local", :txt, ["type=ravenna", "ver=1"], 4500,
            cache_flush: true
          ),
          DNS.record("stagebox.local", :a, {10, 0, 0, 5}, 120, cache_flush: true)
        ]
      })

    mk = fn bin, src ->
      Frame.udp(bin,
        dst_ip: {224, 0, 0, 251},
        dst_port: 5353,
        src_port: 5353,
        src_ip: src,
        ttl: 255
      )
    end

    pkts = Tshark.dissect([mk.(q, {10, 0, 0, 6}), mk.(resp, {10, 0, 0, 5})])
    # Wireshark tracks request and response pairs; the multicast response is not matched
    Tshark.assert_clean(pkts, [~r/DNS response missing/])
    [pq, pr] = pkts

    assert String.ends_with?(Tshark.get(pq, "frame.protocols"), "udp:mdns")
    assert Tshark.get(pq, "dns.qry.name") == "_ravenna_session._sub._rtsp._tcp.local"
    assert Tshark.get(pq, "dns.qry.type") == "12"
    assert Tshark.get(pq, "dns.qry.qu") == "1"
    assert Tshark.get(pq, "dns.flags.response") == "0"

    assert Tshark.get(pr, "dns.flags.response") == "1"
    assert Tshark.get(pr, "dns.flags.authoritative") == "1"
    assert Tshark.get(pr, "dns.count.answers") == "4"
    assert Tshark.get(pr, "dns.ptr.domain_name") == "Stage Box._rtsp._tcp.local"
    assert Tshark.get(pr, "dns.srv.port") == "554"
    assert Tshark.get(pr, "dns.srv.target") == "stagebox.local"
    assert Tshark.all(pr, "dns.txt") == ["type=ravenna", "ver=1"]
    assert Tshark.get(pr, "dns.a") == "10.0.0.5"
    assert Enum.sort(Tshark.all(pr, "dns.resp.type")) == ["1", "12", "16", "33"]
    assert "Stage Box._rtsp._tcp.local" in Tshark.all(pr, "dns.resp.name")
    assert Enum.sort(Tshark.all(pr, "dns.resp.ttl")) == ["120", "120", "4500", "4500"]
  end

  test "RTSP DESCRIBE request and response with an SDP body" do
    sdp = Stream.generate(stream())

    req =
      RTSP.encode(%{
        method: "DESCRIBE",
        uri: "rtsp://10.0.0.5/by-name/Out",
        headers: [{"cseq", "1"}, {"accept", "application/sdp"}],
        body: ""
      })

    res =
      RTSP.encode(%{
        status: 200,
        headers: [{"cseq", "1"}, {"content-type", "application/sdp"}],
        body: sdp
      })

    frames = [
      Frame.tcp(req,
        src_ip: {10, 0, 0, 6},
        dst_ip: {10, 0, 0, 5},
        src_port: 50_000,
        dst_port: 554
      ),
      Frame.tcp(res,
        src_ip: {10, 0, 0, 5},
        dst_ip: {10, 0, 0, 6},
        src_port: 554,
        dst_port: 50_000,
        dst_mac: <<2, 0, 0, 0, 0, 1>>
      )
    ]

    [preq, pres] = pkts = Tshark.dissect(frames, prefs: @tcp_prefs)
    Tshark.assert_clean(pkts)
    assert Tshark.get(preq, "rtsp.method") == "DESCRIBE"
    assert Tshark.get(preq, "rtsp.url") == "rtsp://10.0.0.5/by-name/Out"
    assert Tshark.get(pres, "rtsp.status") == "200"
    assert Tshark.get(pres, "rtsp.content-type") == "application/sdp"
    assert Tshark.get(pres, "rtsp.content-length") == "#{byte_size(sdp)}"
    assert Tshark.get(pres, "sdp.session_name") == "Out 1-2"
    assert Tshark.get(pres, "sdp.media.port") == "5004"

    assert "ts-refclk:ptp=IEEE1588-2008:39-A7-94-FF-FE-07-CB-D0:0" in Tshark.all(
             pres,
             "sdp.media_attr"
           )
  end

  # -- reverse direction: Wireshark sample captures ------------------------------------------

  defp with_capture(name, fun) do
    case Captures.fetch(name) do
      {:skip, why} ->
        IO.puts("skipped #{name}: #{why}")

      {:ok, path} ->
        {1, frames} = Captures.frames(path)
        prefs = @tcp_prefs ++ ["rtp.heuristic_rtp:TRUE"]
        pkts = Tshark.dissect_file(Path.dirname(path), Path.basename(path), prefs: prefs)
        assert length(frames) == length(pkts)
        fun.(Enum.zip(frames, pkts))
    end
  end

  for name <- ["sip-rtp-l16.pcap", "RTP_L16_monaural_sample.pcapng"] do
    test "#{name}: RTP headers and L16 payloads decode like tshark" do
      with_capture(unquote(name), fn pairs ->
        n =
          for {f, p} <- pairs, Tshark.get(p, "rtp.version") == "2", reduce: 0 do
            acc ->
              {:udp, _, pl} = Frame.payload(f)

              assert {:ok, rtp} = RTP.decode(pl),
                     "RTP.decode failed on a frame tshark parses as RTP"

              assert "#{rtp.pt}" == Tshark.get(p, "rtp.p_type")
              assert "#{rtp.seq}" == Tshark.get(p, "rtp.seq")
              assert "#{rtp.ts}" == Tshark.get(p, "rtp.timestamp")

              assert "0x" <>
                       String.pad_leading(
                         Integer.to_string(rtp.ssrc, 16) |> String.downcase(),
                         8,
                         "0"
                       ) == Tshark.get(p, "rtp.ssrc")

              assert if(rtp.marker, do: "1", else: "0") == Tshark.get(p, "rtp.marker")
              assert "#{length(rtp.csrc)}" == Tshark.get(p, "rtp.cc")
              assert hex(rtp.payload) == Tshark.get(p, "rtp.payload")
              # L16 payloads are whole samples
              if rtp.pt in [10, 11] or
                   String.contains?(to_string(Tshark.get(p, "rtp.p_type")), "L16"),
                 do: assert({:ok, _} = Payload.unpack(:l16, rtp.payload, 1))

              acc + 1
          end

        IO.puts("#{unquote(name)}: #{n} RTP packets")
        assert n > 0
      end)
    end
  end

  test "mDNS1.zip: DNS messages decode like tshark" do
    with_capture("mDNS1.zip", fn pairs ->
      n =
        for {f, p} <- pairs, Tshark.get(p, "dns.id") != nil, reduce: 0 do
          acc ->
            {:udp, _, pl} = Frame.payload(f)
            assert {:ok, m} = DNS.decode(pl), "DNS.decode failed: #{inspect(pl)}"
            assert if(m.response, do: "1", else: "0") == Tshark.get(p, "dns.flags.response")
            assert "#{length(m.questions)}" == Tshark.get(p, "dns.count.queries")
            assert "#{length(m.answers)}" == Tshark.get(p, "dns.count.answers")
            assert Enum.map(m.questions, & &1.name) == Tshark.all(p, "dns.qry.name")
            acc + 1
        end

      IO.puts("mDNS1.zip: #{n} DNS messages")
      assert n > 0
    end)
  end

  test "RTSPPACKETS1.cap: RTSP requests and responses decode like tshark" do
    with_capture("RTSPPACKETS1.cap", fn pairs ->
      n =
        for {f, p} <- pairs,
            Tshark.get(p, "rtsp.method") || Tshark.get(p, "rtsp.status"),
            reduce: 0 do
          acc ->
            {:tcp, _, pl} = Frame.payload(f)

            case RTSP.parse(pl) do
              {:ok, msg, _rest} -> check_rtsp(msg, p)
              :more -> :ok
              other -> flunk("RTSP.parse: #{inspect(other)} on #{inspect(pl)}")
            end

            acc + 1
        end

      IO.puts("RTSPPACKETS1.cap: #{n} RTSP messages")
      assert n > 0
    end)
  end

  defp check_rtsp(%{method: m, uri: u}, p) do
    assert m == Tshark.get(p, "rtsp.method")
    assert u == Tshark.get(p, "rtsp.url")
  end

  defp check_rtsp(%{status: s}, p), do: assert("#{s}" == Tshark.get(p, "rtsp.status"))
  _ = SDP
end
