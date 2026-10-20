defmodule ExAes67.Model.Depacketiser do
  @moduledoc """
  Golden model of the RX depacketiser: a stream table lookup on a received
  UDP datagram, followed by per-sample jitter buffer writes.

  A table entry is `%{id, dst_ip, dst_port, ssrc, pt, channels, base_channel,
  format}`; `ssrc: nil` matches any SSRC. Lookup is on destination IP and
  port first, then payload type and SSRC; the first matching entry in table
  order wins. Any UDP port is allowed.

  `process/4` returns the writes `{channel, rtp_ts, sample24}` in frame-major
  order: frame `i` of the packet carries timestamp `ts + i` and channel `c` of
  the stream lands on `base_channel + c`. Samples are signed 24 bit,
  L16 is left-justified (`ExAes67.RTP.Payload.to24/2`).

  Per stream stats: `packets`, `samples`, `lost` (sequence gaps seen),
  `reordered` (sequence behind the expected one, includes duplicates). A
  late packet counts in both, so `lost - reordered` is the net loss when
  nothing is duplicated (off by one when the very first packet is overtaken). Global
  drops are counted by reason: `:bad_rtp`, `:no_stream`, `:bad_length`.

      iex> alias ExAes67.Model.Depacketiser, as: D
      iex> alias ExAes67.{RTP, RTP.Payload}
      iex> entry = %{id: :a, dst_ip: {239, 1, 1, 1}, dst_port: 6000, ssrc: nil, pt: 97, channels: 2, base_channel: 4, format: :l24}
      iex> pkt = RTP.encode(%RTP{pt: 97, seq: 1, ts: 1000, ssrc: 9, payload: Payload.pack(:l24, [[1, 2], [3, 4]])})
      iex> {_d, writes, {:ok, :a}} = D.process(D.new([entry]), {239, 1, 1, 1}, 6000, pkt)
      iex> writes
      [{4, 1000, 1}, {5, 1000, 2}, {4, 1001, 3}, {5, 1001, 4}]
  """
  alias ExAes67.RTP
  alias ExAes67.RTP.Payload

  defstruct table: [], index: %{}, stats: %{}, drops: %{bad_rtp: 0, no_stream: 0, bad_length: 0}

  def new(entries) do
    index = Enum.group_by(entries, &{&1.dst_ip, &1.dst_port})

    stats =
      Map.new(entries, &{&1.id, %{packets: 0, samples: 0, lost: 0, reordered: 0, expected: nil}})

    %__MODULE__{table: entries, index: index, stats: stats}
  end

  @spec process(%__MODULE__{}, tuple(), 0..65535, binary()) ::
          {%__MODULE__{}, [{integer(), integer(), integer()}], {:ok, term()} | {:drop, atom()}}
  def process(%__MODULE__{} = d, dst_ip, dst_port, udp_payload) do
    with {:ok, rtp} <- RTP.decode(udp_payload) |> tag(:bad_rtp),
         {:ok, e} <- find(d, dst_ip, dst_port, rtp) |> tag(:no_stream),
         {:ok, frames} <- Payload.unpack(e.format, rtp.payload, e.channels) |> tag(:bad_length) do
      writes =
        for {frame, i} <- Enum.with_index(frames),
            {s, c} <- Enum.with_index(frame),
            do: {e.base_channel + c, RTP.ts_add(rtp.ts, i), Payload.to24(e.format, s)}

      {account(d, e, rtp.seq, length(frames) * e.channels), writes, {:ok, e.id}}
    else
      {:error, reason} ->
        {%{d | drops: Map.update!(d.drops, reason, &(&1 + 1))}, [], {:drop, reason}}
    end
  end

  defp tag({:ok, _} = ok, _), do: ok
  defp tag(_, reason), do: {:error, reason}

  defp find(d, ip, port, rtp) do
    d.index
    |> Map.get({ip, port}, [])
    |> Enum.find(&(&1.pt == rtp.pt and (&1.ssrc == nil or &1.ssrc == rtp.ssrc)))
    |> case do
      nil -> :error
      e -> {:ok, e}
    end
  end

  defp account(d, e, seq, samples) do
    st = d.stats[e.id]

    {lost, reordered, expected} =
      case st.expected && RTP.seq_diff(seq, st.expected) do
        nil -> {0, 0, RTP.seq_add(seq, 1)}
        0 -> {0, 0, RTP.seq_add(seq, 1)}
        gap when gap > 0 -> {gap, 0, RTP.seq_add(seq, 1)}
        _ -> {0, 1, st.expected}
      end

    st = %{
      st
      | packets: st.packets + 1,
        samples: st.samples + samples,
        lost: st.lost + lost,
        reordered: st.reordered + reordered,
        expected: expected
    }

    %{d | stats: Map.put(d.stats, e.id, st)}
  end
end
