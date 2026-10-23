# Needs from sibling libraries

Nothing blocks the BEAM side or the models. For the hardware step:

## exhdl

* A way to co-simulate a step-function model against RTL with recorded
  traces (inputs per clock, expected outputs per clock). The models in
  `ExAes67.Model.*` are pure `state -> input -> {state, output}` functions
  and would be driven from the same trace format.
* RTL DSL support for a RAM with per-slot tags and a power-of-two address
  mask (jitter buffer, `SampleRing`), and for a sorted/staggered scheduler
  (packetiser).

## ex_net

* Resolved (`ExNet.RTL.UdpRx`): IPv4/UDP receive path that tolerates 802.1Q and IP options and
  hands the depacketiser the UDP payload with `{dst_ip, dst_port, src_ip, len}`.
* Resolved (`ExNet.RTL.UdpTx`, `TxPath`): UDP/IPv4/Ethernet framing for TX with the multicast MAC
  derived from the destination IP.
* Open: IGMP join/leave controlled from the BEAM (SDP session start/stop).

## ex_ptp

* Resolved (`ExPtp.RTL.MediaNco`, `ExPtp.RTL.Ifc.media_clock/2`): media clock from the PTP wall clock
  to the 32 bit RTP timestamp domain, with the `mediaclk:direct` offset.
* Open: grandmaster identity and domain readout for `a=ts-refclk`
  (`SDP.Stream.ptp_refclk/2` takes the 8 byte gmid and the domain).

# Hardware step (wave 2): what the RTL modules expect and what was missing

The RTL is in `lib/ex_aes67/rtl/`; interfaces are documented in
`ExAes67.RTL.Interfaces`. Nothing below blocks the tests, which run on
ExHdl alone.

## exhdl (RTL DSL, simulator, tools)

Each item is a gap that cost a workaround in this library.

* **FSM state is not usable in a memory enable that the FSM body depends
  on.** `in_state/2` needs the handle `fsm/3` returns, but a state body that
  uses read data needs the `read_port` first, and the port's `en:` needs the
  state. Reproducer:

      module "m" do
        mem = memory(:m, width: 8, depth: 16)
        f = fsm :c do
          state :a do
            if rd == 1, do: goto(:b)   # rd is defined below: undefined variable
          end
          state :b, do: goto(:a)
        end
        rd = read_port(mem, addr: 0, en: in_state(f, :a))
      end

  Wanted: `in_state(:c, :a)` by name, or a forward `fsm_state/2`. This
  library uses a plain state register and `switch` instead (the
  `wire(:x, 1)` then `x <~ ...` forward declaration works for plain wires).
* **Zero width pieces.** `slice(x, 1, 0)` and `cat([])` raise, so address
  builders special-case "no group bits" (`ExAes67.RTL.Slots.addr/3`). Wanted:
  `cat/1` that skips `nil` entries, or width 0 allowed in generator code.
* **Yosys URAM counts for widths below 72 are optimistic.**
  `Examples.ram(style: :ultra, width: 56, depth: 65536)` reports 13 URAM288
  from `ExHdl.Synth.Yosys.utilization/3`; URAM288 is always 4096 x 72, so
  Vivado needs 16. `utilization/3` could add `uram_min` (words/4096 times
  ceil(width/72)). Also the summary has `bram18` only; a `bram36` figure
  (RAMB36 counted once) is what data sheets quote.
* **Closed loop co-simulation.** `Cosim` replays a recorded stimulus, so a
  testbench that reacts to `tready`/`wr_ready` has to run in the BEAM
  simulator first and is replayed in Verilator afterwards (what
  `ExAes67.RTLDrv` does). The BEAM simulator runs about 50k cycles/s on
  these modules, and an end-to-end scenario needs 100k to 300k cycles (30 s).
  Wanted: an interactive Verilator session (`Cosim.open/1`, `poke`, `step`,
  `peek` over a pipe) so reactive testbenches run at Verilator speed, and the
  same `Sim`-like API for both.
* **Memory port/clock-enable semantics for TDP inference** are only checked
  in `ExHdl` by counting URAM/BRAM. Here a read port and the write port of
  the jitter buffer share one address wire (read-modify-write on "port A")
  and a second read port scans ("port B"); Yosys infers 8 URAM for 1024 x 64
  with two lanes per word, i.e. no duplication, but there is no way to assert
  "this memory is one true dual port block". A `Yosys` check that a memory
  maps without duplicating (cell count equals the expected tile count) would
  document it.
* **Collision rules.** Same-cycle read of the word being written on the other
  port returns the old word in `Sim` (read-first); on URAM288 the result is
  undefined. The jitter buffer stalls its scan on the address compare; a
  `Sim` option that returns an X marker (or raises) for such a collision
  would have caught missing interlocks.

## ex_net (classifier and TX path)

All of this is `ExNet.RTL.Ifc` now and is built and tested end to end (`test/integration/`):

* RX: AXI4-Stream, 64 bit, byte 0 in `tdata[7:0]`, `tuser` (96 bit) constant over the packet:
  `[31:0]` destination IP, `[47:32]` destination port, `[79:48]` source IP, `[95:80]` UDP payload
  length. Only joined multicast groups or unicast to us (the classifier table), only whole packets
  with a good FCS. Deviation from the wish: the UDP checksum is not verified (the Ethernet FCS
  is; AES67 senders use checksum 0). Backpressure: `UdpRx` has a 512 beat packet FIFO that
  drops whole packets when full (`drop_full`), the depacketiser's two banks sit behind it.
* TX: the same stream with a 64 bit `tuser` valid on every beat: `[31:0]` destination IP,
  `[47:32]` destination port, `[63:48]` UDP payload length; `UdpTx` adds UDP, IPv4 (TTL, TOS,
  source address and port from inputs), the multicast MAC and the Ethernet framing; `tready` may
  stall and `tvalid` may pause, a packet FIFO (`TxPath`) makes the MAC stream gapless.
* IGMP join/leave per stream from the BEAM: open.

## ex_ptp (media clock)

Resolved: `ExPtp.RTL.MediaNco` (ports `tick`, `rtp_ts`, `ExPtp.RTL.Ifc.media_clock/2`) feeds the
jitter buffer and the packetiser in the chains. `tick` and `rtp_ts` change in the same cycle,
ticks are every 192 cycles in the tests (the contract is at least `channels + 16`). A step of
`rtp_ts` after a wallclock step and `align` makes the jitter buffer play silence for the old
slots, as before; nothing flushes it. The per stream `mediaclk:direct` offset stays a table field.

## ex_hdl_cores

* Resolved: the packet FIFO in front of `Depacketiser` is `ExHdlCores.FIFO.packet/1` inside
  `ExNet.RTL.UdpRx` (it also drops bad frames); `TxPath` uses it again on the TX side, with
  `AXIS.merge/2` as the arbiter.
* AXI-Lite to the `cfg_we/cfg_sel/cfg_addr/cfg_data` bus (write only) plus a
  read path for `stat_addr/stat_lane/stat_data`; `ex_pcie` would sit behind it.

## Interop findings

Run against Wireshark 4.4.19, GStreamer 1.26.2 and PipeWire 1.4.2 in containers (README "Interop").

- No protocol bug found in `ExAes67.RTP`, `RTCP`, `SDP`, `SAP`, `DNS`, `RTSP`, `SAP.Server`: packets
  built by the library dissect cleanly in Wireshark with equal fields; GStreamer depayloads
  them bit exactly and PipeWire creates a receiver from the SAP announcement; GStreamer's RTP and
  RTCP and PipeWire's RTP and SAP/SDP (including `a=source-filter: incl ...` with a space after the
  colon, `a=ssrc`, `a=type`, media level `i=`) decode with the library.
- Not covered: PTP locked media clocks (`ts-refclk` is parsed but there is no clock to check),
  `ExAes67.MDNS` and `ExAes67.RTSP.Server` against a real peer (only the codecs against Wireshark's
  dissectors and sample captures; Avahi and an RTSP client are the next candidates), RTCP receiver
  reports into a real sender, ptime below 1 ms (the BEAM sender cannot pace 125 us packets
  reliably, so the interop sender uses 1 ms), aes67-linux-daemon.
- `ExAes67.SAP.Server.announce/3` returns the message id (a number), the docs say nothing about the
  return value; the interop sender ignores it.


## Wave 3 status (interop, integration)

* Full `mix test` exceeds 200 s on this shared host; last run reached two
  failures in `DiscoveryTest` (RTSP raw, SAP on loopback) before timing out.
  Not yet triaged: may be loopback/multicast limits of the host.
* `SIBLINGS_DIR` in `mix.exs` lets the suite run against a snapshot of the
  siblings (`git archive HEAD`) while they are edited. The committed
  siblings lack `ExPtp.RTL.Ifc` and `ExNet.RTL.UdpRx/UdpTx`, so the RTL
  tests need their working copies until those land.
* Interop (`test/interop/`, tagged `:interop`, excluded by default): tshark
  decode, PipeWire SDP and GStreamer L24 round trip are scaffolded but not
  run to completion; the PipeWire null sink recording step is unfinished.
