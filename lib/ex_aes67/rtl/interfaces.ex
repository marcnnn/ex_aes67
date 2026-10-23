defmodule ExAes67.RTL.Interfaces do
  @moduledoc """
  Stream interfaces between `ex_net`, the media clock and these modules. The definitions
  live with the producers and are shared: `ExNet.RTL.Ifc` (`udp_rx/0`, `udp_tx/0`, the
  `tuser` layouts `pack_udp_rx/1`, `pack_udp_tx/1`) and `ExPtp.RTL.Ifc.media_clock/2`.

  ## UDP receive (`udp_rx/0`)

  AXI4-Stream, 64 bit, byte 0 of the UDP payload in `tdata[7:0]`, `tkeep`
  marks valid bytes of the last beat, `tuser` (96 bits) is constant over the packet:

  | `tuser` bits | Field |
  |---|---|
  | `[31:0]` | destination IP (first octet in the MSBs) |
  | `[47:32]` | destination port |
  | `[79:48]` | source IP |
  | `[95:80]` | UDP payload length in bytes |

  `ExNet.RTL.UdpRx` produces it: only frames the classifier steers to a stream engine
  (joined multicast groups or unicast to us), only whole packets with a good FCS, behind a
  packet FIFO that absorbs line rate bursts. The UDP checksum is not verified (AES67
  senders use 0); this module does the RTP level filtering.

  ## UDP transmit (`udp_tx/0`)

  Same stream, `tuser` (64 bits) valid on every beat of a packet:
  `[31:0]` destination IP, `[47:32]` destination port, `[63:48]` UDP
  payload length. `ExNet.RTL.UdpTx` adds UDP, IPv4 (TTL, TOS, source address from its
  configuration inputs), the multicast MAC and the Ethernet framing; `ExNet.RTL.TxPath`
  puts a store-and-forward FIFO behind it, which the packetiser's bursty output needs
  before a MAC (a MAC needs gapless frames). The packetiser may be stalled by `tready` at
  any time; it keeps `tuser` and its beats stable while stalled.

  ## Media clock

  `ExPtp.RTL.Ifc.media_clock(:slave)` declares the two ports:

    * `tick` - one cycle pulse per sample period (48 kHz). Consecutive ticks
      are at least `channels + 16` cycles apart.
    * `rtp_ts` (32 bit) - media time of the sample period that starts with
      the tick: the PTP time in sample periods modulo 2^32. It changes in
      the tick cycle and is stable until the next tick. The per stream
      `mediaclk:direct` offset is added by the packetiser. `ExPtp.RTL.MediaNco` produces it.

  ## Control

  Table and stats access is a plain write bus (`cfg_we`, `cfg_sel`,
  `cfg_addr`, `cfg_data`) in the module's clock domain; put an AXI-Lite
  bridge from `ex_pcie` in front. `ExAes67.RTL.Program` builds the write
  sequences from the stream descriptions the BEAM side already has.
  """

  @doc "UDP payload stream with 96 bit receive metadata (`ExNet.RTL.Ifc.udp_rx/0`)."
  defdelegate udp_rx, to: ExNet.RTL.Ifc

  @doc "UDP payload stream with 64 bit transmit metadata (`ExNet.RTL.Ifc.udp_tx/0`)."
  defdelegate udp_tx, to: ExNet.RTL.Ifc
end
