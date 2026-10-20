defmodule ExAes67.RTCP do
  @moduledoc """
  RTCP (RFC 3550 section 6) compound packet codec: SR, RR, SDES, BYE.
  Other packet types decode to `%{type: :unknown, pt: pt, count: n, body: bin}`.

  A report block is a map with `:ssrc, :fraction_lost, :lost, :highest_seq,
  :jitter, :lsr, :dlsr`.

      iex> rr = %{type: :rr, ssrc: 1, reports: []}
      iex> sdes = %{type: :sdes, chunks: [{1, [{:cname, "ep@host"}]}]}
      iex> bin = ExAes67.RTCP.encode([rr, sdes])
      iex> {:ok, [^rr, ^sdes]} = ExAes67.RTCP.decode(bin)
      iex> rem(byte_size(bin), 4)
      0
  """

  @sdes_types %{
    1 => :cname,
    2 => :name,
    3 => :email,
    4 => :phone,
    5 => :loc,
    6 => :tool,
    7 => :note
  }
  @sdes_ids Map.new(@sdes_types, fn {k, v} -> {v, k} end)

  @spec encode([map()]) :: binary()
  def encode(packets), do: for(p <- packets, into: <<>>, do: enc(p))

  defp enc(%{type: :sr} = p) do
    {msw, lsw} = p.ntp
    body = <<p.ssrc::32, msw::32, lsw::32, p.rtp_ts::32, p.packets::32, p.octets::32>>
    pkt(200, length(p.reports), body <> enc_reports(p.reports))
  end

  defp enc(%{type: :rr} = p),
    do: pkt(201, length(p.reports), <<p.ssrc::32>> <> enc_reports(p.reports))

  defp enc(%{type: :sdes, chunks: chunks}) do
    body =
      for {ssrc, items} <- chunks, into: <<>> do
        its =
          for {t, v} <- items,
              into: <<>>,
              do: <<Map.fetch!(@sdes_ids, t), byte_size(v), v::binary>>

        pad(<<ssrc::32, its::binary, 0>>)
      end

    pkt(202, length(chunks), body)
  end

  defp enc(%{type: :bye} = p) do
    reason =
      case p[:reason] do
        nil -> <<>>
        r -> pad(<<byte_size(r), r::binary>>)
      end

    pkt(203, length(p.ssrcs), for(s <- p.ssrcs, into: <<>>, do: <<s::32>>) <> reason)
  end

  defp enc(%{type: :unknown} = p), do: pkt(p.pt, p.count, p.body)

  defp enc_reports(rs) do
    for r <- rs, into: <<>> do
      <<r.ssrc::32, r.fraction_lost::8, r.lost::signed-24, r.highest_seq::32, r.jitter::32,
        r.lsr::32, r.dlsr::32>>
    end
  end

  defp pkt(pt, count, body) when byte_size(body) |> rem(4) == 0,
    do: <<2::2, 0::1, count::5, pt::8, div(byte_size(body), 4)::16, body::binary>>

  defp pad(bin), do: bin <> :binary.copy(<<0>>, rem(4 - rem(byte_size(bin), 4), 4))

  @spec decode(binary()) :: {:ok, [map()]} | {:error, atom()}
  def decode(bin), do: dec(bin, [])

  defp dec(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp dec(<<2::2, p::1, count::5, pt::8, len::16, rest::binary>>, acc) do
    case rest do
      <<body::binary-size(len * 4), rest::binary>> ->
        with {:ok, body} <- unpad(body, p),
             {:ok, pkt} <- body(pt, count, body) do
          dec(rest, [pkt | acc])
        end

      _ ->
        {:error, :truncated}
    end
  end

  defp dec(<<v::2, _::bitstring>>, _) when v != 2, do: {:error, :bad_version}
  defp dec(_, _), do: {:error, :truncated}

  defp unpad(body, 0), do: {:ok, body}

  defp unpad(body, 1) when byte_size(body) > 0 do
    n = :binary.last(body)

    if n in 1..byte_size(body),
      do: {:ok, binary_part(body, 0, byte_size(body) - n)},
      else: {:error, :bad_padding}
  end

  defp unpad(_, 1), do: {:error, :bad_padding}

  defp body(200, rc, <<ssrc::32, msw::32, lsw::32, ts::32, pc::32, oc::32, rest::binary>>) do
    with {:ok, rs} <- reports(rest, rc) do
      {:ok,
       %{type: :sr, ssrc: ssrc, ntp: {msw, lsw}, rtp_ts: ts, packets: pc, octets: oc, reports: rs}}
    end
  end

  defp body(201, rc, <<ssrc::32, rest::binary>>) do
    with {:ok, rs} <- reports(rest, rc), do: {:ok, %{type: :rr, ssrc: ssrc, reports: rs}}
  end

  defp body(202, n, bin), do: sdes(bin, n, [])

  defp body(203, n, bin) do
    case bin do
      <<s::binary-size(n * 4), rest::binary>> ->
        ssrcs = for <<v::32 <- s>>, do: v

        case rest do
          <<>> -> {:ok, %{type: :bye, ssrcs: ssrcs}}
          <<l, r::binary-size(l), _::binary>> -> {:ok, %{type: :bye, ssrcs: ssrcs, reason: r}}
          _ -> {:error, :truncated}
        end

      _ ->
        {:error, :truncated}
    end
  end

  defp body(pt, _, _) when pt in 200..203, do: {:error, :truncated}
  defp body(pt, n, bin), do: {:ok, %{type: :unknown, pt: pt, count: n, body: bin}}

  defp reports(bin, n) do
    case bin do
      <<b::binary-size(n * 24), _::binary>> ->
        {:ok,
         for <<ssrc::32, fl::8, lost::signed-24, hs::32, j::32, lsr::32, dlsr::32 <- b>> do
           %{
             ssrc: ssrc,
             fraction_lost: fl,
             lost: lost,
             highest_seq: hs,
             jitter: j,
             lsr: lsr,
             dlsr: dlsr
           }
         end}

      _ ->
        {:error, :truncated}
    end
  end

  defp sdes(<<>>, 0, acc), do: {:ok, %{type: :sdes, chunks: Enum.reverse(acc)}}
  defp sdes(_, 0, _), do: {:error, :trailing_data}

  defp sdes(<<ssrc::32, rest::binary>>, n, acc) when n > 0 do
    with {:ok, items, rest} <- sdes_items(rest, [], 4) do
      sdes(rest, n - 1, [{ssrc, items} | acc])
    end
  end

  defp sdes(_, _, _), do: {:error, :truncated}

  # consumed counts bytes after the SSRC, chunks are padded to 32 bits
  defp sdes_items(<<0, rest::binary>>, items, consumed) do
    skip = rem(4 - rem(consumed + 1, 4), 4)

    case rest do
      <<_::binary-size(skip), rest::binary>> -> {:ok, Enum.reverse(items), rest}
      _ -> {:error, :truncated}
    end
  end

  defp sdes_items(<<t, l, v::binary-size(l), rest::binary>>, items, consumed) do
    sdes_items(rest, [{Map.get(@sdes_types, t, t), v} | items], consumed + 2 + l)
  end

  defp sdes_items(_, _, _), do: {:error, :truncated}

  @doc "Splits unix time in microseconds into the 32.32 NTP timestamp pair."
  def ntp_from_unix_us(us) do
    secs = div(us, 1_000_000) + 2_208_988_800
    frac = div(rem(us, 1_000_000) * 4_294_967_296, 1_000_000)
    {secs, frac}
  end
end
