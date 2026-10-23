defmodule ExAes67.Interop.GStreamerTest do
  @moduledoc """
  RTP L16/L24 audio between ex_aes67 and GStreamer 1.26 (`rtpL24pay`/`rtpL24depay`,
  `rtpL16pay`/`rtpL16depay`, Debian trixie) in containers on one podman network, multicast
  239.69.0.x, 48 kHz stereo, 1 ms packets.

  - ExAes67 -> GStreamer: ExAes67.RTP packets with a sample counter; the depayloaded
    audio written by `filesink` must be the same counter sequence (no loss, no reordering,
    no corruption).
  - GStreamer -> ExAes67: a 1 kHz sine from `audiotestsrc`, packets captured with tcpdump
    in the sender's network namespace and decoded with ExAes67.RTP and Payload.
  """
  use ExUnit.Case, async: false

  alias ExAes67.RTP
  alias ExAes67.RTP.Payload
  alias Interop.Aes67

  @moduletag :interop
  @moduletag timeout: 180_000

  @formats %{
    l24: %{
      bytes: 3,
      gst: "S24BE",
      depay: "rtpL24depay",
      pay: "rtpL24pay",
      enc: "L24",
      full: 8_388_607
    },
    l16: %{
      bytes: 2,
      gst: "S16BE",
      depay: "rtpL16depay",
      pay: "rtpL16pay",
      enc: "L16",
      full: 32_767
    }
  }

  defp wait_for_log(name, pattern, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      Process.sleep(250)
      Aes67.logs(name)
    end)
    |> Enum.find(fn log ->
      log =~ pattern or System.monotonic_time(:millisecond) > deadline
    end)
    |> then(fn log ->
      assert log =~ pattern, "timeout waiting for #{inspect(pattern)} in:\n#{log}"
    end)
  end

  defp wait_gone(name, tries \\ 40) do
    {out, _} = Aes67.podman(["ps", "-q", "--filter", "name=^#{name}$"])

    cond do
      String.trim(out) == "" -> :ok
      tries == 0 -> flunk("container #{name} did not stop")
      true -> Process.sleep(250) && wait_gone(name, tries - 1)
    end
  end

  # sample generator of aes67_send.exs, pattern "counter"
  defp counter(:l24, n, c), do: rem(n, 0x7FFFFF) * if(c == 0, do: 1, else: -1)
  defp counter(:l16, n, c), do: rem(rem(n, 0x7FFFFF), 0x7FFF) * if(c == 0, do: 1, else: -1)

  for fmt <- [:l24, :l16] do
    test "ExAes67 #{fmt} stream is received by GStreamer unchanged" do
      fmt = unquote(fmt)
      f = @formats[fmt]
      Interop.Podman.require_image!("gstreamer")
      dir = Aes67.tmp_dir()
      name = Aes67.unique("ex-interop-gst-rx")

      caps =
        "application/x-rtp,media=(string)audio,clock-rate=(int)48000," <>
          "encoding-name=(string)#{f.enc},channels=(int)2,payload=(int)98"

      pipeline =
        "exec gst-launch-1.0 -e udpsrc address=239.69.0.1 port=5004 multicast-iface=eth0 " <>
          "auto-multicast=true caps=\"#{caps}\" ! rtpjitterbuffer latency=20 ! #{f.depay} ! " <>
          "audio/x-raw,format=#{f.gst},rate=48000,channels=2 ! filesink location=/out/rx.raw"

      Aes67.start(name, [
        "--userns=keep-id",
        "-v",
        "#{dir}:/out:z",
        Interop.Podman.image("gstreamer"),
        "sh",
        "-c",
        pipeline
      ])

      wait_for_log(name, "Setting pipeline to PLAYING", 20_000)
      Process.sleep(1_500)

      out =
        Aes67.send_stream(
          group: "239.69.0.1",
          packets: 3000,
          encoding: fmt,
          pt: 98,
          pattern: "counter",
          lead_ms: 300
        )

      assert out =~ "SENT 3000"
      # the jitter buffer holds back its last packets; EOS on INT flushes what it released
      Process.sleep(500)
      Aes67.podman(["kill", "-s", "INT", name])
      wait_gone(name)

      raw = File.read!(Path.join(dir, "rx.raw"))
      width = 2 * f.bytes
      assert byte_size(raw) > 0
      assert rem(byte_size(raw), width) == 0

      frames = decode_raw(fmt, raw)

      # 3000 packets of 48 frames; at most a few are held back or lost at start and end
      assert length(frames) > 0.9 * 3000 * 48, "only #{length(frames)} frames of #{3000 * 48}"
      {n0, _} = hd(frames)
      assert n0 < 100 * 48

      bad =
        frames
        |> Enum.with_index()
        |> Enum.count(fn {{a, b}, i} ->
          {a, b} != {counter(fmt, n0 + i, 0), counter(fmt, n0 + i, 1)}
        end)

      assert bad == 0, "#{bad} of #{length(frames)} frames differ from the sent counter"
    end

    test "GStreamer #{fmt} stream (audiotestsrc sine) is decoded by ExAes67" do
      fmt = unquote(fmt)
      f = @formats[fmt]
      name = Aes67.unique("ex-interop-gst-tx")
      Aes67.holder("gstreamer", name)
      dir = Aes67.tmp_dir()
      stop = Aes67.capture(name, dir, "udp port 5004 and dst host 239.69.0.2")

      {out, _} =
        Aes67.exec(name, [
          "timeout",
          "-s",
          "INT",
          "6",
          "gst-launch-1.0",
          "-e",
          "audiotestsrc",
          "wave=sine",
          "freq=1000",
          "volume=0.5",
          "is-live=true",
          "samplesperbuffer=48",
          "!",
          "audio/x-raw,format=#{f.gst},rate=48000,channels=2",
          "!",
          f.pay,
          "pt=98",
          "min-ptime=1000000",
          "max-ptime=1000000",
          "!",
          "udpsink",
          "host=239.69.0.2",
          "port=5004",
          "multicast-iface=eth0",
          "auto-multicast=true",
          "ttl-mc=4"
        ])

      assert out =~ "Setting pipeline to PLAYING"
      frames = stop.()
      pkts = Aes67.rtp_packets(frames, 5004)
      assert length(pkts) > 3_000, "only #{length(pkts)} RTP packets"

      # every packet is a plain RTP v2 packet with the payload type asked for, one SSRC
      assert Enum.all?(
               pkts,
               &(&1.pt == 98 and &1.version == 2 and &1.csrc == [] and &1.ext == nil)
             )

      assert pkts |> Enum.map(& &1.ssrc) |> Enum.uniq() |> length() == 1

      # 1 ms packets: 48 frames, sequence +1, timestamp +48
      assert Enum.all?(pkts, &(byte_size(&1.payload) == 48 * 2 * f.bytes))
      steps = Aes67.steps(pkts)
      assert steps[{1, 48}] >= 0.99 * (length(pkts) - 1), inspect(steps)

      # contiguous run of the stream: decode and check the signal
      run = contiguous_run(pkts)
      samples = for p <- run, do: elem(Payload.unpack(fmt, p.payload, 2), 1)
      frames = List.flatten(samples |> Enum.map(&Enum.map(&1, fn [l, r] -> {l, r} end)))
      left = Enum.map(frames, &elem(&1, 0))
      right = Enum.map(frames, &elem(&1, 1))
      assert left == right

      # a sine of period 48 samples: x[n+48] = x[n] up to rounding, 3 % amplitude tolerance
      # (skip the first packets, audiotestsrc ramps nothing but the pipeline settles)
      e = Aes67.sine_error(Enum.drop(left, 480), f.full, 2)
      assert e.ok, inspect(e)
      assert_in_delta e.peak_ratio, 1.0, 0.03
    end
  end

  test "GStreamer rtpbin RTCP sender reports and SDES are decoded by ExAes67" do
    name = Aes67.unique("ex-interop-gst-rtcp")
    Aes67.holder("gstreamer", name)
    dir = Aes67.tmp_dir()
    stop = Aes67.capture(name, dir, "udp port 5004 or udp port 5005")

    {out, _} =
      Aes67.exec(name, [
        "timeout",
        "-s",
        "INT",
        "12",
        "gst-launch-1.0",
        "-e",
        "rtpbin",
        "name=rtpbin",
        "audiotestsrc",
        "wave=sine",
        "freq=1000",
        "volume=0.5",
        "is-live=true",
        "samplesperbuffer=48",
        "!",
        "audio/x-raw,format=S24BE,rate=48000,channels=2",
        "!",
        "rtpL24pay",
        "pt=98",
        "min-ptime=1000000",
        "max-ptime=1000000",
        "!",
        "rtpbin.send_rtp_sink_0",
        "rtpbin.send_rtp_src_0",
        "!",
        "udpsink",
        "host=239.69.0.3",
        "port=5004",
        "multicast-iface=eth0",
        "auto-multicast=true",
        "ttl-mc=4",
        "rtpbin.send_rtcp_src_0",
        "!",
        "udpsink",
        "host=239.69.0.3",
        "port=5005",
        "multicast-iface=eth0",
        "auto-multicast=true",
        "ttl-mc=4",
        "sync=false",
        "async=false"
      ])

    assert out =~ "Setting pipeline to PLAYING"
    frames = stop.()
    rtp = Aes67.rtp_packets(frames, 5004)
    ssrc = hd(rtp).ssrc

    compounds =
      for f <- frames, {:udp, 5005, pl} <- [Interop.Frame.payload(f)] do
        assert {:ok, pkts} = ExAes67.RTCP.decode(pl)
        pkts
      end

    assert length(compounds) >= 2
    assert Enum.all?(compounds, &match?([%{type: :sr}, %{type: :sdes} | _], &1))

    for [sr, sdes | _] <- compounds do
      assert sr.ssrc == ssrc
      assert sr.reports == []
      # 48 frames of stereo L24 per packet
      assert sr.octets == 288 * sr.packets
      assert sr.packets > 0 and sr.packets <= length(rtp)
      # NTP seconds are since 1900
      {msw, _lsw} = sr.ntp
      assert_in_delta msw - 2_208_988_800, System.os_time(:second), 600
      assert [{^ssrc, items}] = sdes.chunks
      assert items[:cname] =~ "@"
      assert items[:tool] == "GStreamer"
    end

    # the sender report counters grow with the stream
    [first | _] = compounds
    last = List.last(compounds)
    assert hd(last).packets > hd(first).packets
  end

  defp decode_raw(:l24, raw), do: for(<<a::signed-24, b::signed-24 <- raw>>, do: {a, b})
  defp decode_raw(:l16, raw), do: for(<<a::signed-16, b::signed-16 <- raw>>, do: {a, b})

  defp contiguous_run(pkts) do
    pkts
    |> Enum.chunk_while(
      [],
      fn p, acc ->
        case acc do
          [] ->
            {:cont, [p]}

          [prev | _] ->
            if RTP.seq_diff(p.seq, prev.seq) == 1,
              do: {:cont, [p | acc]},
              else: {:cont, Enum.reverse(acc), [p]}
        end
      end,
      fn acc -> {:cont, Enum.reverse(acc), []} end
    )
    |> Enum.max_by(&length/1)
  end
end
