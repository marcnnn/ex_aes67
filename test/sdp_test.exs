defmodule ExAes67.SDPTest do
  use ExUnit.Case, async: true
  alias ExAes67.SDP
  alias ExAes67.SDP.Stream

  @gmid <<0x39, 0xA7, 0x94, 0xFF, 0xFE, 0x07, 0xCB, 0xD0>>

  @annex """
  v=0
  o=- 1311738121 1311738121 IN IP4 192.168.1.1
  s=Stage left I/O
  c=IN IP4 239.0.0.1/32
  t=0 0
  a=recvonly
  m=audio 5004 RTP/AVP 96
  c=IN IP4 239.0.0.1/32
  a=rtpmap:96 L24/48000/8
  a=sync-time:0
  a=framecount:48
  a=ptime:1
  a=mediaclk:direct=963214424
  a=ts-refclk:ptp=IEEE1588-2008:39-A7-94-FF-FE-07-CB-D0:0
  """

  @dante """
  v=0\r
  o=- 1423986 1423994 IN IP4 169.254.98.63\r
  s=AVIOUSB-064f5f_1\r
  i=2 channels: 01, 02\r
  c=IN IP4 239.69.202.32/32\r
  t=0 0\r
  a=keywds:Dante\r
  m=audio 5004 RTP/AVP 97\r
  i=1 ch\r
  a=recvonly\r
  a=rtpmap:97 L24/48000/2\r
  a=ptime:1\r
  a=ts-refclk:ptp=IEEE1588-2008:00-1D-C1-FF-FE-0A-1B-2C:0\r
  a=mediaclk:direct=0\r
  """

  @ravenna """
  v=0
  o=- 3925551 3925553 IN IP4 192.168.1.50
  s=Merging Anubis 1
  i=RAVENNA stream
  c=IN IP4 239.1.2.3/15
  t=0 0
  a=clock-domain:PTPv2 0
  a=source-filter: incl IN IP4 239.1.2.3 192.168.1.50
  m=audio 5004 RTP/AVP 98
  a=rtpmap:98 L16/44100/2
  a=sync-time:0
  a=framecount:11
  a=ptime:0.25
  a=maxptime:4
  a=mediaclk:direct=1234
  a=ts-refclk:ptp=IEEE1588-2008:00-1D-C1-FF-FE-00-AA-BB:3
  a=sendonly
  a=x-vendor-private:whatever
  m=video 5006 RTP/AVP 99
  a=rtpmap:99 H264/90000
  """

  test "AES67 spec style example" do
    assert {:ok, sdp} = SDP.parse(@annex)
    assert sdp.name == "Stage left I/O"
    assert {:ok, [s]} = SDP.streams(sdp)

    assert %Stream{
             dest_ip: {239, 0, 0, 1},
             ttl: 32,
             port: 5004,
             pt: 96,
             encoding: :l24,
             rate: 48_000,
             channels: 8,
             ptime: 1.0,
             framecount: 48,
             mediaclk: {:direct, 963_214_424},
             sync_time: 0,
             direction: :recvonly,
             origin_addr: "192.168.1.1"
           } = s

    assert s.ts_refclk == %{type: :ptp, version: "IEEE1588-2008", gmid: @gmid, domain: 0}
    assert Stream.packet_time_us(s) == 1000
  end

  test "Dante AES67 mode with CRLF, media level direction and session extras" do
    assert {:ok, sdp} = SDP.parse(@dante)
    assert SDP.attr(sdp.attrs, "keywds") == "Dante"
    assert {:ok, [s]} = SDP.streams(sdp)

    assert {s.channels, s.direction, s.info, s.dest_ip} ==
             {2, :recvonly, "1 ch", {239, 69, 202, 32}}

    assert s.ts_refclk.gmid == <<0, 0x1D, 0xC1, 0xFF, 0xFE, 0x0A, 0x1B, 0x2C>>
  end

  test "RAVENNA quirks: clock-domain, 44.1 kHz, source filter, unknown media, vendor attrs" do
    assert {:ok, sdp} = SDP.parse(@ravenna)
    assert {:ok, [s]} = SDP.streams(sdp)

    assert {s.encoding, s.rate, s.ttl, s.ptime, s.maxptime, s.framecount} ==
             {:l16, 44_100, 15, 0.25, 4.0, 11}

    assert s.clock_domain == {"PTPv2", 0}
    assert s.ts_refclk.domain == 3
    assert s.direction == :sendonly
    assert s.source_filter == %{mode: :incl, dest: {239, 1, 2, 3}, sources: [{192, 168, 1, 50}]}
    assert length(sdp.media) == 2
  end

  test "tolerant parsing" do
    text = """
    v=0
    o=- 1 1 IN IP4 10.0.0.1
    garbage line
    c=IN IP4 239.1.1.1/16
    t=0 0
    m=audio 5004 RTP/AVP 97 98
    a=rtpmap:97 l24/48000
    a=ptime:.125
    a=mediaclk:direct
    a=ts-refclk:localmac=00-11-22-33-44-55
    a=maxptime
    """

    assert {:ok, sdp} = SDP.parse(text)
    assert sdp.name == ""
    assert {:ok, [s]} = SDP.streams(sdp)

    assert {s.channels, s.ptime, s.mediaclk, s.ts_refclk} ==
             {1, 0.125, {:direct, nil}, %{type: :localmac, mac: "00-11-22-33-44-55"}}

    assert Stream.packet_time_us(s) == 125
  end

  test "ts-refclk variants" do
    parse = fn v ->
      {:ok, sdp} =
        SDP.parse(
          "v=0\no=- 1 1 IN IP4 1.1.1.1\nc=IN IP4 239.1.1.1\nm=audio 1 RTP/AVP 97\na=rtpmap:97 L24/48000/2\na=ts-refclk:#{v}\n"
        )

      {:ok, [s]} = SDP.streams(sdp)
      s.ts_refclk
    end

    assert parse.("ptp=IEEE1588-2008:traceable") == %{
             type: :ptp,
             version: "IEEE1588-2008",
             traceable: true
           }

    assert parse.("ptp=IEEE1588-2008:39-A7-94-FF-FE-07-CB-D0").domain == 0

    assert parse.("ptp=IEEE1588-2002:39:A7:94:FF:FE:07:CB:D0:5") |> Map.take([:domain, :version]) ==
             %{domain: 5, version: "IEEE1588-2002"}

    assert parse.("ntp=pool.ntp.org") == %{type: :other, value: "ntp=pool.ntp.org"}
  end

  test "session level attributes apply, media level overrides" do
    text = """
    v=0
    o=- 1 1 IN IP4 1.1.1.1
    s=x
    c=IN IP4 239.1.1.1/32
    t=0 0
    a=ptime:1
    a=sendonly
    m=audio 5004 RTP/AVP 97
    a=rtpmap:97 L16/48000/2
    a=ptime:4
    m=audio 5006 RTP/AVP 97
    a=rtpmap:97 L24/48000/2
    a=inactive
    """

    {:ok, sdp} = SDP.parse(text)
    {:ok, [a, b]} = SDP.streams(sdp)
    assert {a.ptime, a.direction, b.ptime, b.direction} == {4.0, :sendonly, 1.0, :inactive}
  end

  test "errors" do
    assert {:error, :no_version} = SDP.parse("")
    assert {:error, :bad_version} = SDP.parse("v=1\n")

    assert {:ok, sdp} =
             SDP.parse("v=0\no=- 1 1 IN IP4 1.1.1.1\nm=audio 1 RTP/AVP 0\na=rtpmap:0 PCMU/8000\n")

    assert {:error, :no_audio} = SDP.streams(sdp)
  end

  test "generic round trip keeps structure" do
    {:ok, sdp} = SDP.parse(@ravenna)
    assert {:ok, ^sdp} = sdp |> SDP.to_string() |> SDP.parse()
    {:ok, sdp} = SDP.parse(@annex)
    assert {:ok, ^sdp} = sdp |> SDP.to_string() |> SDP.parse()
  end

  test "generated SDP has the AES67 shape" do
    s = %Stream{
      name: "Out",
      origin_addr: "10.0.0.5",
      sess_id: "42",
      sess_version: "43",
      dest_ip: {239, 69, 1, 1},
      port: 5004,
      pt: 98,
      channels: 8,
      ptime: 0.125,
      maxptime: 4,
      framecount: 6,
      ts_refclk: Stream.ptp_refclk(@gmid, 0),
      mediaclk: {:direct, 77},
      direction: :sendonly,
      source_filter: %{mode: :incl, dest: {239, 69, 1, 1}, sources: [{10, 0, 0, 5}]}
    }

    text = Stream.generate(s)
    assert text =~ "o=- 42 43 IN IP4 10.0.0.5\r\n"
    assert text =~ "c=IN IP4 239.69.1.1/32\r\n"
    assert text =~ "a=rtpmap:98 L24/48000/8\r\n"
    assert text =~ "a=ptime:0.125\r\n"
    assert text =~ "a=maxptime:4\r\n"
    assert text =~ "a=ts-refclk:ptp=IEEE1588-2008:39-A7-94-FF-FE-07-CB-D0:0\r\n"
    assert text =~ "a=mediaclk:direct=77\r\n"
    assert text =~ "a=source-filter:incl IN IP4 239.69.1.1 10.0.0.5\r\n"
    {:ok, sdp} = SDP.parse(text)
    {:ok, [back]} = SDP.streams(sdp)
    assert back == %{s | ttl: 32, maxptime: 4.0, info: nil}
  end

  test "unicast destination has no ttl" do
    s = %Stream{name: "u", dest_ip: {10, 0, 0, 9}, origin_addr: "10.0.0.1"}
    assert Stream.generate(s) =~ "c=IN IP4 10.0.0.9\r\n"
  end
end
