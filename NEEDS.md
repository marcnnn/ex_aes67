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

* IPv4/UDP receive parser that tolerates 802.1Q and IP options (CRIT-01) and
  hands `{dst_ip, dst_port, udp_payload}` to the depacketiser. The model
  takes exactly that triple.
* UDP/IPv4/Ethernet framing for TX with multicast MAC derived from the
  destination IP; the packetiser model emits `udp_payload` only.
* IGMP join/leave controlled from the BEAM (SDP session start/stop).

## ex_ptp

* Media clock: a function from the PTP wall clock to the 32 bit RTP
  timestamp domain at 48 kHz (and the current `mediaclk:direct` offset), so
  the jitter buffer `now` and the packetiser `now` have a defined source.
* Grandmaster identity and domain readout for `a=ts-refclk`
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

* RX: AXI4-Stream, 64 bit, byte 0 in `tdata[7:0]`, `tuser` (96 bit) valid on
  the first beat: `[31:0]` destination IP, `[47:32]` destination port,
  `[79:48]` source IP, `[95:80]` UDP payload length. UDP checksum verified,
  only joined multicast groups or unicast to us. Backpressure is honoured but
  put a FIFO of a few packets in front (the depacketiser has two 2 KB banks).
* TX: the same stream with a 64 bit `tuser`, valid on every beat of a packet:
  `[31:0]` destination IP, `[47:32]` destination port, `[63:48]` UDP payload
  length. `ex_net` adds UDP, IPv4, the multicast MAC derived from the IP and
  the Ethernet framing. One packet at a time, `tready` may stall.
* IGMP join/leave per stream from the BEAM (unchanged from above).

## ex_ptp (media clock)

* `tick` (one cycle pulse per 48 kHz sample period) and `rtp_ts` (32 bit media
  time of the period starting at the tick, changes with the tick, stable
  until the next one), in the clock domain of the RTP modules (CDC done in
  `ex_ptp`). Ticks at least `channels + 16` cycles apart for the jitter
  buffer, and a continuous `rtp_ts` (steps: the tags make the jitter buffer
  play silence, as the model does, but nothing flushes it).
* The per stream `mediaclk:direct` offset is a table field here, so `ex_ptp`
  only provides the common counter.

## ex_hdl_cores

* A packet FIFO (store and forward, a few KB) in front of
  `Depacketiser`'s `s_axis` when the classifier can burst at line rate.
* AXI-Lite to the `cfg_we/cfg_sel/cfg_addr/cfg_data` bus (write only) plus a
  read path for `stat_addr/stat_lane/stat_data`; `ex_pcie` would sit behind it.
