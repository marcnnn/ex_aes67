defmodule ExAes67.RTL.Interfaces do
  @moduledoc """
  Stream interfaces between `ex_net`, the media clock and these modules.

  `ex_net` and `ex_ptp` are not dependencies; these are the interfaces this
  library expects from them.

  ## UDP receive (`udp_rx/0`)

  AXI4-Stream, 64 bit, byte 0 of the UDP payload in `tdata[7:0]`, `tkeep`
  marks valid bytes of the last beat, `tuser` carries metadata and is valid
  on the first beat of a packet:

  | `tuser` bits | Field |
  |---|---|
  | `[31:0]` | destination IP (first octet in the MSBs) |
  | `[47:32]` | destination port |
  | `[79:48]` | source IP |
  | `[95:80]` | UDP payload length in bytes |

  The classifier forwards only datagrams it has matched to an AES67 stream
  (multicast groups joined or unicast address) and has already checked the
  UDP checksum; this module does the RTP level filtering.

  ## UDP transmit (`udp_tx/0`)

  Same stream, `tuser` (64 bits) valid on every beat of a packet:
  `[31:0]` destination IP, `[47:32]` destination port, `[63:48]` UDP
  payload length. `ex_net`'s TX path adds UDP, IPv4 (TTL, DSCP from its
  own configuration), the multicast MAC and the Ethernet framing.

  ## Media clock

  Two signals from `ex_ptp`, in the domain of the module that uses them:

    * `tick` - one cycle pulse per sample period (48 kHz). Consecutive ticks
      are at least `channels + 16` cycles apart.
    * `rtp_ts` (32 bit) - media time of the sample period that starts with
      the tick: the PTP time in sample periods modulo 2^32. It changes in
      the tick cycle and is stable until the next tick. The per stream
      `mediaclk:direct` offset is added by the packetiser.

  ## Control

  Table and stats access is a plain write bus (`cfg_we`, `cfg_sel`,
  `cfg_addr`, `cfg_data`) in the module's clock domain; put an AXI-Lite
  bridge from `ex_pcie` in front. `ExAes67.RTL.Program` builds the write
  sequences from the stream descriptions the BEAM side already has.
  """
  alias ExHdl.RTL.Interface

  @doc "UDP payload stream with 96 bit receive metadata."
  def udp_rx, do: Interface.axi_stream(data: 64, user: 96)

  @doc "UDP payload stream with 64 bit transmit metadata."
  def udp_tx, do: Interface.axi_stream(data: 64, user: 64)
end
