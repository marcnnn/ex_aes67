defmodule ExAes67.Interop.PipeWireTest do
  @moduledoc """
  AES67 style streams with PipeWire 1.4.2 (`module-rtp-sap`, `module-rtp-source`,
  `module-rtp-sink`, WirePlumber, null sink; Debian trixie), in containers on a podman
  network, no PTP (the SDP carries a `ts-refclk` but the media clock is free running).

  - ExAes67 -> PipeWire: ExAes67.SDP and ExAes67.SAP announce a stream, ExAes67.RTP packets
    carry a 1 kHz sine. PipeWire creates a receiver from the announcement; the audio
    recorded from the null sink monitor must be that sine.
  - PipeWire -> ExAes67: PipeWire announces its RTP sink by SAP and sends L24 packets; the
    captured SAP is parsed with ExAes67.SAP and SDP, the RTP with ExAes67.RTP and Payload,
    and the same capture is dissected by tshark.
  """
  use ExUnit.Case, async: false

  import Bitwise, only: [<<<: 2, >>>: 2]

  alias ExAes67.{RTP, SDP}
  alias ExAes67.RTP.Payload
  alias Interop.{Aes67, Tshark}

  @moduletag :interop
  @moduletag timeout: 240_000

  @support Path.join(__DIR__, "support/pipewire")

  defp pipewire(confs) do
    Interop.Podman.require_image!("pipewire")
    conf_dir = Aes67.tmp_dir()
    for c <- confs, do: File.cp!(Path.join(@support, c), Path.join(conf_dir, c))
    out = Aes67.tmp_dir()
    name = Aes67.unique("ex-interop-pw")

    Aes67.start(name, [
      "--security-opt",
      "label=disable",
      "-v",
      "#{conf_dir}:/etc/pipewire/pipewire.conf.d:ro",
      "-v",
      "#{out}:/out",
      Interop.Podman.image("pipewire"),
      "sh",
      "-c",
      "export XDG_RUNTIME_DIR=/tmp/xdg; mkdir -p $XDG_RUNTIME_DIR; pipewire & sleep 1; " <>
        "wireplumber > /out/wp.log 2>&1 & wait"
    ])

    wait_nodes(name, "aes67-null")
    {name, out}
  end

  defp pw(name, cmd), do: Aes67.exec(name, ["sh", "-c", cmd], env: [XDG_RUNTIME_DIR: "/tmp/xdg"])

  defp wait_nodes(name, node, tries \\ 40) do
    {out, _} = pw(name, "pw-cli ls Node")

    cond do
      out =~ node -> :ok
      tries == 0 -> flunk("PipeWire did not come up:\n#{Aes67.logs(name)}")
      true -> Process.sleep(500) && wait_nodes(name, node, tries - 1)
    end
  end

  # s32le stereo from pw-cat (the 24 bit sample is in the upper bits; pw-cat has no packed s24)
  defp s32le(raw),
    do: for(<<l::signed-little-32, r::signed-little-32 <- raw>>, do: {l >>> 8, r >>> 8})

  # The sine of the test signal, 1 kHz at half scale (period 48 samples)
  defp ref(k), do: round(0.5 * 8_388_607 * :math.sin(2 * :math.pi() * k / 48))

  # The active part of a channel (leading and trailing silence removed) as
  # `{samples, median_10ms_peak, zero_crossings_per_second}`. A 1 kHz sine has 2000 crossings per second.
  defp tone(samples) do
    active =
      samples
      |> Enum.drop_while(&(&1 == 0))
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == 0))
      |> Enum.reverse()

    signs = active |> Enum.reject(&(&1 == 0)) |> Enum.map(&(&1 > 0))
    crossings = signs |> Enum.chunk_every(2, 1, :discard) |> Enum.count(fn [a, b] -> a != b end)
    # median of the 10 ms peaks (a recording glitch can produce a stray full scale sample)
    peaks =
      active
      |> Enum.chunk_every(480, 480, :discard)
      |> Enum.map(fn c -> c |> Enum.map(&abs/1) |> Enum.max() end)
      |> Enum.sort()

    peak = Enum.at(peaks, div(length(peaks), 2))
    {active, peak, crossings / (length(active) / 48_000)}
  end

  test "ExAes67 SAP/SDP announcement and RTP stream are received by PipeWire" do
    {pw, out} = pipewire(["rx-10-sap.conf", "null-sink.conf", "quantum-192.conf"])

    sender =
      Task.async(fn ->
        Aes67.send_stream(
          group: "239.69.0.1",
          packets: 10_000,
          encoding: :l24,
          pattern: "sine",
          sap: true,
          sap_seconds: 2,
          name: "ExAes67 test"
        )
      end)

    # SAP announcements are repeated every second; PipeWire creates the receiver on the first
    Process.sleep(4_000)
    {nodes, _} = pw(pw, "pw-cli ls Node")
    assert nodes =~ ~s(node.name = "ExAes67 test")
    assert nodes =~ ~s(media.class = "Stream/Output/Audio")

    {rec, _} =
      pw(
        pw,
        "timeout -s INT 4 pw-cat -r --rate 48000 --channels 2 --format s32 --raw " <>
          "-P stream.capture.sink=true --target aes67-null - > /out/rec.raw"
      )

    _ = rec
    assert Task.await(sender, 60_000) =~ "SENT 10000"

    frames = out |> Path.join("rec.raw") |> File.read!() |> s32le()
    left = Enum.map(frames, &elem(&1, 0))
    right = Enum.map(frames, &elem(&1, 1))
    equal = left |> Enum.zip(right) |> Enum.count(fn {l, r} -> abs(l - r) <= 2 end)
    assert equal >= 0.9 * length(left), "#{equal} of #{length(left)} frames have equal channels"

    # the receiver resamples to follow the sender's clock (BEAM paced, not PTP) and a
    # non-realtime PipeWire in a container glitches now and then (a glitch shifts the phase
    # of the sine), so the check is: a 1 kHz tone at half scale, at least 2 s of it
    {active, peak, crossings} = tone(left)
    assert length(active) >= 2 * 48_000, "only #{length(active)} active frames"
    # the receiver's resampler and pw-cat's recording glitches blur the level: 25 %
    assert_in_delta peak, 4_194_304, 0.25 * 4_194_304
    # glitches (silence inserted by the graph) remove crossings, they do not add any
    assert crossings >= 1_200 and crossings <= 2_100, "#{crossings} zero crossings per second"
  end

  test "PipeWire SAP/SDP announcement and RTP stream are decoded by ExAes67 and Wireshark" do
    {pw, _out} = pipewire(["tx-10-rtp-sink-sap.conf", "null-sink.conf", "quantum-192.conf"])
    dir = Aes67.tmp_dir()
    stop = Aes67.capture(pw, dir, "(udp port 5004 and dst host 239.69.0.9) or udp port 9875")

    # 4 s of the sine, s32le stereo, played into the null sink whose monitor feeds rtp-sink
    in_dir = Aes67.tmp_dir()

    sine =
      for n <- 0..(4 * 48_000 - 1), into: <<>> do
        v = ref(rem(n, 48))
        <<v <<< 8::signed-little-32, v <<< 8::signed-little-32>>
      end

    File.write!(Path.join(in_dir, "sine.raw"), sine)
    {_, 0} = Aes67.podman(["cp", Path.join(in_dir, "sine.raw"), "#{pw}:/tmp/sine.raw"])

    {_, _} =
      pw(
        pw,
        "cat /tmp/sine.raw | timeout -s INT 8 pw-cat -p --rate 48000 --channels 2 " <>
          "--format s32 --raw --target aes67-null -"
      )

    Process.sleep(1_000)
    frames = stop.()

    # -- SAP and SDP
    saps = Aes67.sap_packets(frames)
    assert saps != []
    sap = hd(saps)
    assert sap.type == :announce
    assert sap.payload_type == "application/sdp"
    assert {:ok, sdp} = SDP.parse(sap.payload)
    assert {:ok, [s]} = SDP.streams(sdp)
    assert s.name == "PipeWire AES67"
    assert s.dest_ip == {239, 69, 0, 9}
    assert s.port == 5004
    assert {s.encoding, s.rate, s.channels} == {:l24, 48_000, 2}
    assert s.ptime == 1.0
    assert SDP.Stream.packet_time_us(s) == 1000
    assert s.ts_refclk.type == :ptp
    assert s.ts_refclk.gmid == <<0x39, 0xA7, 0x94, 0xFF, 0xFE, 0x07, 0xCB, 0xD0>>
    assert s.source_filter.dest == {239, 69, 0, 9}

    # -- RTP
    pkts = Aes67.rtp_packets(frames, 5004)
    assert length(pkts) > 1_000
    assert Enum.all?(pkts, &(&1.pt == s.pt and &1.version == 2))
    assert pkts |> Enum.map(& &1.ssrc) |> Enum.uniq() |> length() == 1
    assert Enum.all?(pkts, &(rem(byte_size(&1.payload), 6) == 0))

    # sequence +1 and timestamp +frames of the previous packet, wherever PipeWire flushed
    # more than 1 ms at a time
    consistent =
      pkts
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] ->
        RTP.seq_diff(b.seq, a.seq) == 1 and
          RTP.ts_diff(b.ts, a.ts) == div(byte_size(a.payload), 6)
      end)

    assert consistent >= 0.95 * (length(pkts) - 1), "#{consistent} of #{length(pkts) - 1}"

    left =
      pkts
      |> Enum.flat_map(fn p ->
        {:ok, fr} = Payload.unpack(:l24, p.payload, 2)
        Enum.map(fr, fn [l, _] -> l end)
      end)

    # PipeWire sends the samples unchanged: every sample is one of the 48 values of the
    # sine in the file, in whatever order. (The null sink fed by pw-cat in a non-realtime
    # container glitches now and then and shifts the phase of the sine, so the order is not
    # checked, only the tone: 1 kHz, half scale.)
    {active, peak, crossings} = tone(left)
    assert length(active) >= 2 * 48_000, "only #{length(active)} active frames"
    values = MapSet.new(for k <- 0..47, do: ref(k))
    in_set = Enum.count(active, &MapSet.member?(values, &1))
    assert in_set == length(active), "#{length(active) - in_set} samples are not sine values"
    assert_in_delta peak, 4_194_304, 2
    # glitches (silence inserted by the graph) remove crossings, they do not add any
    assert crossings >= 1_200 and crossings <= 2_100, "#{crossings} zero crossings per second"

    # -- the same capture through Wireshark
    pcap = Tshark.dissect_file(dir, "cap.pcap")
    assert length(pcap) == length(frames)
    sdp_pkts = for p <- pcap, Tshark.get(p, "sdp.session_name") != nil, do: p
    assert sdp_pkts != []
    assert Tshark.get(hd(sdp_pkts), "sdp.session_name") == "PipeWire AES67"
    rtp_pkts = for p <- pcap, Tshark.get(p, "rtp.version") != nil, do: p
    assert length(rtp_pkts) == length(pkts)
    assert Enum.all?(rtp_pkts, &(Tshark.get(&1, "rtp.version") == "2"))
    # no malformed packets (expert warnings about RTP timestamps of this unsynchronised
    # stream are not what this checks)
    refute Enum.any?(pcap, &Map.has_key?(&1, "_ws.malformed"))
  end
end
