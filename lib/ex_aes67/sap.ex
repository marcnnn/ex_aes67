defmodule ExAes67.SAP do
  @moduledoc """
  SAP (RFC 2974) packet codec. Compressed and encrypted packets are
  rejected. Authentication data is skipped on decode.

  A packet is `%{type: :announce | :delete, msg_id: 0..65535, origin: ip,
  payload_type: "application/sdp", payload: binary}`.

      iex> pkt = %{type: :announce, msg_id: 0x1234, origin: {10, 0, 0, 1}, payload: "v=0\\r\\n"}
      iex> bin = ExAes67.SAP.encode(pkt)
      iex> {:ok, back} = ExAes67.SAP.decode(bin)
      iex> {back.type, back.msg_id, back.origin, back.payload_type, back.payload}
      {:announce, 4660, {10, 0, 0, 1}, "application/sdp", "v=0\\r\\n"}
  """

  @mime "application/sdp"

  @spec encode(map()) :: binary()
  def encode(%{type: type, msg_id: id, origin: origin, payload: payload} = p) do
    t = if type == :delete, do: 1, else: 0
    {a, addr} = addr(origin)
    mime = Map.get(p, :payload_type, @mime)

    <<1::3, a::1, 0::1, t::1, 0::1, 0::1, 0::8, id::16, addr::binary, mime::binary, 0,
      payload::binary>>
  end

  defp addr({a, b, c, d}), do: {0, <<a, b, c, d>>}

  defp addr(t) when tuple_size(t) == 8,
    do: {1, for(x <- Tuple.to_list(t), into: <<>>, do: <<x::16>>)}

  @spec decode(binary()) :: {:ok, map()} | {:error, atom()}
  def decode(<<1::3, a::1, _r::1, t::1, e::1, c::1, auth::8, id::16, rest::binary>>) do
    cond do
      e == 1 -> {:error, :encrypted}
      c == 1 -> {:error, :compressed}
      true -> decode_body(a, t, auth, id, rest)
    end
  end

  def decode(<<v::3, _::bitstring>>) when v != 1, do: {:error, :bad_version}
  def decode(_), do: {:error, :truncated}

  defp decode_body(a, t, auth, id, rest) do
    size = if a == 0, do: 4, else: 16

    with <<addr::binary-size(size), rest::binary>> <- rest,
         <<_::binary-size(auth * 4), rest::binary>> <- rest do
      origin =
        if a == 0,
          do: List.to_tuple(:binary.bin_to_list(addr)),
          else: List.to_tuple(for <<x::16 <- addr>>, do: x)

      {mime, payload} = split_payload(rest)

      {:ok,
       %{
         type: if(t == 1, do: :delete, else: :announce),
         msg_id: id,
         origin: origin,
         payload_type: mime,
         payload: payload
       }}
    else
      _ -> {:error, :truncated}
    end
  end

  # Legacy senders omit the MIME type and start the SDP directly.
  defp split_payload("v=0" <> _ = p), do: {@mime, p}

  defp split_payload(bin) do
    case :binary.split(bin, <<0>>) do
      [mime, payload] -> {mime, payload}
      [payload] -> {@mime, payload}
    end
  end

  @doc "Message id hash for an SDP text (never 0)."
  def msg_id(sdp), do: rem(:erlang.phash2(sdp, 65_535), 65_535) + 1
end
