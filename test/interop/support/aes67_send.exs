# Runs inside the ex-interop-beam container: sends an AES67 style RTP stream built with
# ExAes67 and, optionally, announces its SDP by SAP.
#
#   elixir -pa "/libs/*/ebin" /support/aes67_send.exs key=value ...
#
# Keys: group (239.69.0.1), port (5004), packets (2000), ptime_us (1000), channels (2),
# encoding (l24|l16), pt (98), ssrc, pattern (counter|sine), sap (true|false),
# sap_seconds (how long to keep announcing after the stream), name, lead_ms (wait before sending).
# Sample pattern: counter: channel 0 is the sample index, channel 1 its negative;
# sine: 1 kHz at half scale on all channels.
args =
  System.argv()
  |> Enum.map(&String.split(&1, "=", parts: 2))
  |> Map.new(fn [k, v] -> {k, v} end)

str = fn k, d -> args[k] || d end
int = fn k, d -> if args[k], do: String.to_integer(args[k]), else: d end

alias ExAes67.RTP
alias ExAes67.RTP.Payload
alias ExAes67.SDP.Stream

{:ok, ifs} = :inet.getifaddrs()
iface = hd(for {n, o} <- ifs, n != ~c"lo", {:addr, {_, _, _, _} = a} <- o, do: a)
{:ok, group} = :inet.parse_address(String.to_charlist(str.("group", "239.69.0.1")))
port = int.("port", 5004)
npk = int.("packets", 2000)
ptime_us = int.("ptime_us", 1000)
ch = int.("channels", 2)
enc = String.to_atom(str.("encoding", "l24"))
pt = int.("pt", 98)
ssrc = int.("ssrc", 0x1A2B3C4D)
rate = 48_000
frames = div(rate * ptime_us, 1_000_000)
pattern = str.("pattern", "counter")
gm = <<0x39, 0xA7, 0x94, 0xFF, 0xFE, 0x07, 0xCB, 0xD0>>

stream = %Stream{
  name: str.("name", "ExAes67 test"),
  origin_addr: :inet.ntoa(iface) |> List.to_string(),
  sess_id: "1311738121",
  sess_version: "1",
  dest_ip: group,
  port: port,
  pt: pt,
  encoding: enc,
  rate: rate,
  channels: ch,
  ptime: ptime_us / 1000,
  ts_refclk: Stream.ptp_refclk(gm, 0),
  mediaclk: {:direct, 0},
  direction: :sendonly
}

sdp = Stream.generate(stream)
IO.puts("SDP\n" <> sdp)

sample = fn n, c ->
  case pattern do
    "counter" ->
      v = rem(n, 0x7FFFFF)

      if enc == :l16,
        do: rem(v, 0x7FFF) * if(c == 0, do: 1, else: -1),
        else: v * if(c == 0, do: 1, else: -1)

    "sine" ->
      full = if enc == :l24, do: 8_388_607, else: 32_767
      round(0.5 * full * :math.sin(2 * :math.pi() * 1000 * n / rate))
  end
end

{:ok, sock} =
  :gen_udp.open(0, [
    :binary,
    ip: iface,
    multicast_if: iface,
    multicast_ttl: 4,
    multicast_loop: false
  ])

sap =
  if args["sap"] == "true" do
    {:ok, s} =
      ExAes67.SAP.Server.start_link(
        port: 0,
        dest: {{239, 255, 255, 255}, 9875},
        origin: iface,
        interval: 1_000
      )

    _ = ExAes67.SAP.Server.announce(s, "ch1", sdp)
    s
  end

Process.sleep(int.("lead_ms", 0))
t0 = System.monotonic_time(:microsecond)

for i <- 0..(npk - 1) do
  due = t0 + i * ptime_us
  wait = due - System.monotonic_time(:microsecond)
  if wait > 1500, do: Process.sleep(div(wait, 1000) - 1)
  while = fn while -> if System.monotonic_time(:microsecond) < due, do: while.(while) end
  while.(while)

  base = i * frames
  fr = for f <- 0..(frames - 1), do: for(c <- 0..(ch - 1), do: sample.(base + f, c))

  pkt = %RTP{
    pt: pt,
    seq: rem(i, 65_536),
    ts: rem(i * frames, 0x100000000),
    ssrc: ssrc,
    payload: Payload.pack(enc, fr)
  }

  :ok = :gen_udp.send(sock, group, port, RTP.encode(pkt))
end

IO.puts("SENT #{npk}")
if sap, do: Process.sleep(int.("sap_seconds", 0) * 1000)
if sap, do: ExAes67.SAP.Server.withdraw(sap, "ch1")
Process.sleep(500)
