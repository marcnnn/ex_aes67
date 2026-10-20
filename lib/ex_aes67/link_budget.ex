defmodule ExAes67.LinkBudget do
  @moduledoc """
  Ethernet link budget for AES67 streams (arithmetic from the intercom
  SCALING notes).

  Wire bytes per packet are preamble and SFD 8, MAC 14 (+4 with a VLAN tag),
  IPv4 20, UDP 8, RTP 12, payload, FCS 4 and inter-frame gap 12; frames
  shorter than 64 bytes (without preamble and gap) are padded. Options:
  `:format` (`:l24`), `:rate` (48_000), `:vlan` (false).

      iex> alias ExAes67.LinkBudget, as: LB
      iex> LB.wire_bytes(1, 1000)
      222
      iex> LB.streams_per_link(1, 1000, 1.0)
      563
      iex> LB.streams_per_link(8, 1000, 1.0)
      101
  """
  alias ExAes67.RTP.Payload

  @doc "Samples per channel in one packet; raises unless integral."
  def frames_per_packet(ptime_us, rate \\ 48_000) do
    if rem(ptime_us * rate, 1_000_000) != 0,
      do: raise(ArgumentError, "ptime is not a whole number of samples")

    div(ptime_us * rate, 1_000_000)
  end

  @doc "RTP payload bytes of one packet."
  def payload_bytes(channels, ptime_us, opts \\ []) do
    rate = Keyword.get(opts, :rate, 48_000)

    channels * frames_per_packet(ptime_us, rate) *
      Payload.bytes_per_sample(Keyword.get(opts, :format, :l24))
  end

  @doc "Bytes one packet occupies on the wire including preamble, FCS and gap."
  def wire_bytes(channels, ptime_us, opts \\ []) do
    vlan = if Keyword.get(opts, :vlan, false), do: 4, else: 0
    frame = 14 + vlan + 20 + 8 + 12 + payload_bytes(channels, ptime_us, opts) + 4
    8 + max(frame, 64) + 12
  end

  @doc "Packets per second of one stream."
  def packets_per_second(ptime_us, rate \\ 48_000), do: rate / frames_per_packet(ptime_us, rate)

  @doc "Wire bit rate of one stream in bit/s."
  def stream_bps(channels, ptime_us, opts \\ []),
    do:
      wire_bytes(channels, ptime_us, opts) * 8 *
        packets_per_second(ptime_us, Keyword.get(opts, :rate, 48_000))

  @doc "Whole streams that fit a link of `gbps`, optionally scaled by `:headroom` (e.g. 0.85)."
  def streams_per_link(channels, ptime_us, gbps, opts \\ []) do
    budget = gbps * 1.0e9 * Keyword.get(opts, :headroom, 1.0)
    trunc(budget / stream_bps(channels, ptime_us, opts) + 1.0e-9)
  end

  @doc "Fraction of the link used by `n` identical streams."
  def utilisation(n, channels, ptime_us, gbps, opts \\ []),
    do: n * stream_bps(channels, ptime_us, opts) / (gbps * 1.0e9)

  @doc "Rows `{channels, streams, total_channels}` for a link speed."
  def table(channel_counts, ptime_us, gbps, opts \\ []) do
    for c <- channel_counts do
      n = streams_per_link(c, ptime_us, gbps, opts)
      {c, n, n * c}
    end
  end
end
