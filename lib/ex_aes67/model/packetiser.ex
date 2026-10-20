defmodule ExAes67.Model.Packetiser do
  @moduledoc """
  Golden model of the TX packetiser.

  Time is the media clock as an unbounded sample counter; the RTP timestamp
  is `(media time + ts_offset) mod 2^32` (`a=mediaclk:direct=<offset>`).
  Packet boundaries are aligned to multiples of the samples per packet
  (`spp = ptime * rate`, which must be integral), so a stream with 1 ms
  packets starts a packet every 48 frames of media time.

  Stagger: stream with table position `i` sends the packet covering frames
  `[s, s + spp)` at media time `s + spp + (i mod spp)`, which spreads the
  streams over the packet interval without configuration.

  Stream config: `%{id, channels, base_channel, ptime_us (125..4000), format,
  pt, ssrc, dst_ip, dst_port}` and optional `seq0` (0), `ts_offset` (0),
  `rate` (48_000). `base_channel` addresses the `SampleRing`. Samples are
  signed 24 bit; L16 takes the top 16 bits (floor). A stale ring slot is sent
  as silence and counted in `stats.silence`.

  `tick/3` emits every packet due up to `now`, ordered by due time then
  table position. With `max_per_tick: n` at most `n` go out per call and the
  excess is dropped (counted in `stats.oversubscribed`, sequence number not
  consumed), mirroring a scheduler that runs out of frame time.

      iex> alias ExAes67.Model.{Packetiser, SampleRing}
      iex> cfg = %{id: 1, channels: 1, base_channel: 0, ptime_us: 125, format: :l24, pt: 97,
      ...>   ssrc: 5, dst_ip: {239, 1, 1, 1}, dst_port: 5004}
      iex> ring = Enum.reduce(0..5, SampleRing.new(depth: 8), &SampleRing.write(&2, 0, &1, &1 * 10))
      iex> {_p, [pkt]} = Packetiser.tick(Packetiser.new([cfg]), ring, 6)
      iex> {pkt.rtp.ts, pkt.rtp.seq, byte_size(pkt.udp_payload)}
      {0, 0, 30}
  """
  alias ExAes67.RTP
  alias ExAes67.RTP.Payload

  defstruct streams: [], max_per_tick: nil, stats: %{oversubscribed: 0, silence: 0, packets: 0}

  @doc "Options: `:now` (media time at start, default 0), `:max_per_tick`."
  def new(configs, opts \\ []) do
    now = Keyword.get(opts, :now, 0)

    streams =
      for {cfg, i} <- Enum.with_index(configs) do
        cfg = Map.merge(%{seq0: 0, ts_offset: 0, rate: 48_000}, cfg)
        spp = samples_per_packet(cfg)

        if cfg.ptime_us not in 125..4000 or
             spp * cfg.channels * Payload.bytes_per_sample(cfg.format) > 1460,
           do:
             raise(ArgumentError, "stream #{inspect(cfg.id)}: ptime or payload size out of range")

        %{
          cfg: cfg,
          spp: spp,
          index: i,
          stagger: rem(i, spp),
          next: div(now + spp - 1, spp) * spp,
          seq: cfg.seq0
        }
      end

    %__MODULE__{streams: streams, max_per_tick: opts[:max_per_tick]}
  end

  defp samples_per_packet(%{ptime_us: p, rate: r}) do
    if rem(p * r, 1_000_000) != 0,
      do: raise(ArgumentError, "ptime is not a whole number of samples")

    div(p * r, 1_000_000)
  end

  @doc """
  Returns `{state, packets}`. A packet is `%{stream, due, dst_ip, dst_port, rtp,
  udp_payload}`.
  """
  def tick(%__MODULE__{} = p, ring, now) do
    due =
      for s <- p.streams,
          start <- starts(s, now),
          do: {start + s.spp + s.stagger, s.index, start}

    due = Enum.sort(due)
    {keep, drop} = if p.max_per_tick, do: Enum.split(due, p.max_per_tick), else: {due, []}

    {streams, pkts, silence} =
      Enum.reduce(keep, {Map.new(p.streams, &{&1.index, &1}), [], 0}, fn {at, i, start},
                                                                         {m, out, sil} ->
        s = m[i]
        {pkt, missing} = build(s, ring, start, at)
        {Map.put(m, i, %{s | seq: RTP.seq_add(s.seq, 1)}), [pkt | out], sil + missing}
      end)

    streams =
      for s <- p.streams do
        s = streams[s.index]
        %{s | next: s.next + length(starts(s, now)) * s.spp}
      end

    stats = %{
      p.stats
      | oversubscribed: p.stats.oversubscribed + length(drop),
        silence: p.stats.silence + silence,
        packets: p.stats.packets + length(keep)
    }

    {%{p | streams: streams, stats: stats}, Enum.reverse(pkts)}
  end

  defp starts(s, now) do
    Stream.iterate(s.next, &(&1 + s.spp))
    |> Enum.take_while(&(&1 + s.spp + s.stagger <= now))
  end

  defp build(s, ring, start, at) do
    cfg = s.cfg

    {frames, missing} =
      Enum.map_reduce(start..(start + s.spp - 1), 0, fn t, miss ->
        Enum.map_reduce(0..(cfg.channels - 1), miss, fn c, miss ->
          case ExAes67.Model.SampleRing.read(ring, cfg.base_channel + c, t) do
            {:ok, v} -> {Payload.from24(cfg.format, v), miss}
            :stale -> {0, miss + 1}
          end
        end)
      end)

    rtp = %RTP{
      pt: cfg.pt,
      seq: s.seq,
      ts: RTP.ts_add(start, cfg.ts_offset),
      ssrc: cfg.ssrc,
      payload: Payload.pack(cfg.format, frames)
    }

    pkt = %{
      stream: cfg.id,
      due: at,
      dst_ip: cfg.dst_ip,
      dst_port: cfg.dst_port,
      rtp: rtp,
      udp_payload: RTP.encode(rtp)
    }

    {pkt, missing}
  end
end
