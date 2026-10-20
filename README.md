# ExAes67

AES67 / RAVENNA streaming: RTP in hardware, discovery and connection
management on the BEAM.

## Status

The BEAM side, the bit-exact reference models and the RTL (ExHdl.RTL) of the
RX depacketiser, jitter buffer and TX packetiser are implemented and tested
against the models in the BEAM simulator and Verilator. Not synthesised
beyond Yosys resource counts, not on hardware, not timing-closed.

| Part | Where | Module | State |
|---|---|---|---|
| RTP header, CSRC, extension, padding, wraparound arithmetic | BEAM + hardware | `ExAes67.RTP` | done |
| L16/L24 payload, RTCP SR/RR/SDES/BYE | BEAM | `ExAes67.RTP.Payload`, `ExAes67.RTCP` | done |
| SDP with AES67 / RAVENNA / Dante attributes | BEAM | `ExAes67.SDP`, `ExAes67.SDP.Stream` | done |
| SAP codec, announcer, listener, directory | BEAM | `ExAes67.SAP`, `ExAes67.SAP.Server` | done |
| mDNS / DNS-SD codec, responder, browser | BEAM | `ExAes67.DNS`, `ExAes67.MDNS` | done, minimal |
| RTSP DESCRIBE server and client | BEAM | `ExAes67.RTSP`, `.Server`, `.Client` | done |
| NMOS IS-04 / IS-05 | BEAM | `ExAes67.NMOS` | stub, see plan |
| Jitter buffer addressed by RTP timestamp | hardware | `ExAes67.Model.JitterBuffer`, `ExAes67.RTL.JitterBuffer` | RTL, co-simulated |
| RX depacketiser with stream table | hardware | `ExAes67.Model.Depacketiser`, `ExAes67.RTL.Depacketiser` | RTL, co-simulated |
| TX packetiser, media-clock pacing, staggering | hardware | `ExAes67.Model.Packetiser`, `.SampleRing`, `ExAes67.RTL.Packetiser` | RTL, co-simulated |
| Link budget | tooling | `ExAes67.LinkBudget` | done |
| ST 2022-7 redundancy | hardware | | later |

Interop targets: PipeWire's AES67 module, aes67-linux-daemon, Dante devices
in AES67 mode. Not yet tested against any of them; the SDP samples in the
tests are written from memory.

## RTL

`ExAes67.RTL.*` are `ExHdl.RTL` modules (`mix format` imports the DSL from
`:ex_hdl`). Every module is a `build/1` function returning an
`%ExHdl.RTL.Module{}`; emit SystemVerilog with
`ExHdl.Backends.SystemVerilog.RTL.generate/1`.

| Module | Role | Main ports |
|---|---|---|
| `RTL.Depacketiser` | UDP payload stream to `{channel, rtp_ts, sample}` writes | `s_axis_*` (64 bit + 96 bit `tuser`), `cfg_*`, `stat_*`, `wr_*`, `st_*` |
| `RTL.JitterBuffer` | `{channel, ts mod depth}` slots with timestamp tags, TDM playout | `wr_*`, `tick`, `rtp_ts`, `latency`, `out_*`, `st_*` |
| `RTL.Packetiser` | sample ring, staggered scheduler, RTP header and L16/L24 payload | `in_*` (TDM), `tick`, `rtp_ts`, `cfg_*`, `m_axis_*` (64 bit + 64 bit `tuser`), `st_*` |
| `RTL.Rx` | Depacketiser feeding the jitter buffer | both sets of ports |
| `RTL.Program` | model stream descriptions to `cfg_*` write sequences | |
| `RTL.Slots` | slot word layout and address math shared by ring and buffer | |
| `RTL.Interfaces` | stream interface definitions and the expected `ex_net` / `ex_ptp` signals | |

Interfaces expected from the siblings (they are not dependencies, see
`ExAes67.RTL.Interfaces` and `NEEDS.md`):

* UDP payload AXI4-Stream, 64 bit, byte 0 in `tdata[7:0]`; RX `tuser` is
  `{payload length 16, source IP 32, destination port 16, destination IP 32}`
  (LSB last), valid on the first beat; TX `tuser` is `{length 16, port 16, IP 32}`
  on every beat.
* Media clock `{tick, rtp_ts}`: a one cycle `tick` per 48 kHz sample period and
  the 32 bit media time of that period, changing with the tick.
* Control: a write bus `cfg_we/cfg_sel/cfg_addr/cfg_data` per module, built from
  the model stream maps by `RTL.Program.rx/2` and `RTL.Program.tx/2`.

Behaviour against the models:

* Depacketiser: identical writes, per stream stats (packets, samples, lost,
  reordered) and drop counts. Differences: CSRC/extension/padding packets and
  packets over the 2 KB bank count as `bad_rtp` / `bad_length`; the lookup is a
  hash of chains instead of a scan (first match in table order is kept).
* Jitter buffer: identical frames and counters (`written late overrun
  duplicate bad_channel underrun played`) when writes and the scan do not
  overlap; overlapping writes use a per channel play instant (the cycle the
  channel is read). A write is two cycles (read-modify-write for the
  duplicate check), the scan reads one channel per cycle on the other port.
* Packetiser: identical bytes, order and tick of emission. The model's
  `max_per_tick` drop becomes lateness (`st_late`). First packet start and
  stagger are table values computed by `RTL.Program.tx/2`, so the hardware
  needs no divider.

### Resources

Yosys 0.69+20 `synth_xilinx -family xcup` (XCKU3P: 360 BRAM36, 48 URAM288), from
`ExHdl.Synth.Yosys.utilization/3`; synthesis only, no timing.

| Block | LUT | FF | DSP | BRAM36 | URAM |
|---|---|---|---|---|---|
| Depacketiser, 512 streams, 1024 hash buckets, 2 x 2 KB banks | 868 | 941 | 1 | 8 | 0 |
| Jitter buffer 1024 ch x 64 frames, `tag_bits: 11`, `style: :ultra` | 462 | 423 | 0 | 0 | 8 |
| same, `tag_bits: 32` (exact model tags) | 748 | 425 | 0 | 0 | 16 (Yosys says 14) |
| same, `style: :block` | 464 | 423 | 0 | 64 | 0 |
| Packetiser, 512 streams, ring 1024 ch x 128 frames, `tag_bits: 11`, ultra | 1371 | 487 | 1 | 4 | 16 |
| same, `tag_bits: 32` | 1769 | 508 | 1 | 4 | 32 (Yosys says 28) |

Slot memory: a slot is `{valid, tag, sample24}`. With `tag_bits <= 11` two
slots share a 72 bit URAM word (36 bit lanes, 4 of the URAM's 9 bit write
enables each), so 1024 x 64 x 24 bit of samples (1.5 Mb) cost 8 URAM
(2.3 Mb, 67%). The tag is the low timestamp bits; a stale slot of a channel
that went silent replays after `2^(tag_bits + log2 depth)` frames (2^17 frames,
2.7 s, with 11 bits), so `tag_bits: 32` is the default and matches the model
exactly. Three 24 bit samples per word (6 URAM) would need read-modify-write
for the lane writes, which the one write per two cycles budget does not
allow. RX and TX together at 1024 channels: 8 + 16 URAM with 11 bit tags
(24 of 48), 16 + 32 with 32 bit tags (all of them): leave the matrix less.
The TX ring depth only has to cover `spp + stagger + 1` frames.

Cycle budget per sample period (3255 cycles at 156.25 MHz, 5208 at 250 MHz):

| Load | RX | TX |
|---|---|---|
| 1024 channels as 1024 x 1 ch, 1 ms | 77% | 68% |
| 1024 channels as 128 x 8 ch, 1 ms | 65% | 36% |
| 1024 x 1 ch, 125 us | 180% (needs a faster jitter buffer write) | 105% (66% at 250 MHz) |

RX: about 22 cycles per packet plus two per sample (one jitter buffer write per
two cycles). TX: one cycle per table slot per scan plus 8 per packet and one
per sample.

### Tests

`test/rtl/` drives the RTL in the BEAM simulator with StreamData stimulus and
compares with the models; tests tagged `:verilator` replay the recorded
stimulus in Verilator and require identical outputs on every cycle (they are
excluded automatically when `verilator` is not in `PATH`).

* `depacketiser_test`: random tables (colliding hash buckets, shared IP and
  port) and packets (bad version, short, wrong length, unknown stream, wrong PT
  and SSRC), random sink stalls.
* `jitter_buffer_test`: random writes (late, overrun, duplicate, bad channel)
  and ticks around the 2^32 wrap, tag widths 32 and 11, plus writes during the
  scan (Verilator against BEAM).
* `packetiser_test`: random stream tables, ring writes skipped (silence),
  output backpressure, bytes and emission tick against `Model.Packetiser`.
* `e2e_test`: RTL packetiser, network with reorder, loss, duplicates, RTL
  receive path; every scenario of `E2ETest`, with the receive path also run
  through the models on the same arrivals (frames and counters equal).

## API overview

```elixir
alias ExAes67.{RTP, RTCP, SDP, SAP, MDNS, RTSP, LinkBudget}
alias ExAes67.RTP.Payload

# RTP
bin = RTP.encode(%RTP{pt: 97, seq: 1, ts: 48_000, ssrc: 1, payload: Payload.pack(:l24, [[1, 2]])})
{:ok, pkt} = RTP.decode(bin)
RTP.ts_diff(5, 0xFFFFFFFB)                 # 10, signed serial arithmetic

# SDP
{:ok, sdp} = SDP.parse(text)
{:ok, [stream]} = SDP.streams(sdp)         # %SDP.Stream{dest_ip:, port:, channels:, ptime:, ts_refclk:, ...}
SDP.Stream.generate(stream)                # AES67 style SDP text

# Discovery and control
{:ok, sap} = SAP.Server.start_link(join: {{239, 255, 255, 255}, my_ip}, origin: my_ip)
SAP.Server.announce(sap, "ch1", text); SAP.Server.sessions(sap)
{:ok, mdns} = MDNS.start_link(join: {{224, 0, 0, 251}, my_ip})
MDNS.register(mdns, %{instance: "Box", type: "_rtsp._tcp", subtypes: ["_ravenna_session"], host: "box", port: 554, ip: my_ip})
MDNS.browse(mdns, "_ravenna_session._sub._rtsp._tcp")
{:ok, rtsp} = RTSP.Server.start_link(port: 554)
RTSP.Server.put_session(rtsp, "/by-name/Box", text)
{:ok, text} = RTSP.Client.describe("rtsp://10.0.0.5/by-name/Box")

LinkBudget.table([1, 2, 4, 8], 1000, 1.0)  # [{1, 563, 563}, {2, 341, 682}, ...]
```

SAP, mDNS and RTSP take `:port` (0 for ephemeral) and `:dest`, so they run
on loopback without multicast. Tests that need a multicast capable
interface are tagged `:multicast` and excluded by default
(`mix test --include multicast`).

## Reference models

Pure step functions, no processes, no wall clock. Time is the media clock
passed in by the caller. Samples are signed 24 bit (L16 is left justified).

| Model | Step function | Output |
|---|---|---|
| `JitterBuffer` | `write(jb, ch, rtp_ts, sample)`, `play(jb, now)` | `:ok / :late / :overrun / :duplicate / :bad_channel`; one frame per `play`, silence plus `underrun` count for missing samples |
| `Depacketiser` | `process(d, dst_ip, dst_port, udp_payload)` | `{d, [{channel, rtp_ts, sample}], {:ok, id} or {:drop, reason}}` |
| `Packetiser` | `tick(p, sample_ring, now)` | `{p, [%{stream, due, dst_ip, dst_port, rtp, udp_payload}]}` |
| `SampleRing` | `write/4`, `read/3` | `{:ok, sample}` or `:stale` |

Jitter buffer: slot per `{channel, ts mod depth}` (depth a power of two)
tagged with the full timestamp, playout reads `now - latency`, a write is
late if behind the playout position and an overrun if a full depth ahead.
The first copy of a duplicate wins.

Packetiser: packet boundaries are multiples of the samples per packet on the
media clock, stream `i` sends at `start + spp + (i mod spp)`, RTP timestamp is
media time plus the `mediaclk:direct` offset. Packets are produced with
`RTP.encode/1`, so they are bit identical to the codec. Oversubscription
(`max_per_tick`) drops packets and counts them.

## NMOS plan

IS-04 and IS-05 are HTTP and JSON, which this library does not pull in
yet. Plan:

1. Add `bandit` (or `plug_cowboy`) and `jason` as an optional dependency set
   behind a separate application or `only:` flag.
2. IS-04 node API (`/x-nmos/node/v1.3/`): self, devices, sources, flows,
   senders, receivers generated from `SDP.Stream` structs; register with a
   registry found through `_nmos-register._tcp` mDNS browse (reuse
   `ExAes67.MDNS`).
3. IS-05 connection API (`/x-nmos/connection/v1.1/`): staged and active
   parameters, `transport_file` carrying the SDP from `SDP.Stream.generate/1`,
   immediate activation first, scheduled activation later. Activation writes the
   RX stream table (`Depacketiser` entries) or a TX stream config.
4. Advertise `_nmos-node._tcp` through mDNS.

## Not done

* mDNS: no probing, conflict resolution, known-answer suppression or
  periodic re-query. Labels containing dots are not supported.
* SAP: no compression, encryption or authentication, no announcement
  interval scaling or jitter.
* RTSP: DESCRIBE and OPTIONS only (what RAVENNA needs); no SETUP/PLAY.
* SDP: no `a=ssrc`, `a=extmap`, ST 2022-7 `a=group` handling beyond keeping
  attributes verbatim.
* IPv6 is only handled in the codecs.

## The hardware library set

ExHdl itself only provides the basics (RTL DSL, simulation, SystemVerilog,
targets, tool drivers). Function lives in these siblings:

| Library | Scope |
|---|---|
| [ex_hdl_cores](../ex_hdl_cores) | generic IP: FIFOs, CRC, arbiters, AXI4-Stream plumbing |
| [ex_hdl_xilinx](../ex_hdl_xilinx) | Xilinx primitives, constraints, boards |
| [ex_net](../ex_net) | Ethernet MAC, PCS, VLAN/IPv4/UDP/IGMP |
| [ex_ptp](../ex_ptp) | IEEE 1588: timestamping, wallclock, servo, BMCA |
| [ex_aes67](../ex_aes67) | RTP streams, jitter buffer, SAP/SDP, RTSP, mDNS, NMOS |
| [ex_audio](../ex_audio) | audio DSP kernels: EQ, dynamics, matrix mixer, meters |
| [ex_pcie](../ex_pcie) | PCIe DMA and BAR access, host side over vfio |

## Development

```sh
./scripts/checkout_siblings.sh   # path dependencies
mix test
```

`mix test` runs on loopback only. `ex_net` and `ex_ptp` are not dependencies
yet. The RTL tests take about a minute (Verilator builds are cached).
