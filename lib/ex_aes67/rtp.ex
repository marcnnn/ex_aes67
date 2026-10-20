defmodule ExAes67.RTP do
  @moduledoc """
  RTP (RFC 3550) fixed header codec with CSRC list, header extension and
  padding, plus serial number arithmetic for the 16 bit sequence number and
  the 32 bit timestamp.

  `padding` is the total number of padding bytes (0 = no P bit). `ext` is
  `{profile_id, data}` with `data` a multiple of four bytes.

      iex> p = %ExAes67.RTP{pt: 97, seq: 7, ts: 1000, ssrc: 0xCAFE, payload: <<1, 2, 3>>}
      iex> bin = ExAes67.RTP.encode(p)
      iex> byte_size(bin)
      15
      iex> {:ok, ^p} = ExAes67.RTP.decode(bin)
      iex> ExAes67.RTP.seq_diff(2, 65_535)
      3
  """
  import Bitwise

  defstruct version: 2,
            marker: false,
            pt: 0,
            seq: 0,
            ts: 0,
            ssrc: 0,
            csrc: [],
            ext: nil,
            payload: <<>>,
            padding: 0

  @type t :: %__MODULE__{}

  @doc "Serialises a packet."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{csrc: csrc, ext: ext, padding: pad} = p)
      when length(csrc) <= 15 and pad in 0..255 and p.pt in 0..127 do
    {x, ext_bin} = encode_ext(ext)

    {pbit, pad_bin} =
      if pad > 0, do: {1, :binary.copy(<<0>>, pad - 1) <> <<pad>>}, else: {0, <<>>}

    m = if p.marker, do: 1, else: 0

    <<2::2, pbit::1, x::1, length(csrc)::4, m::1, p.pt::7, p.seq::16, p.ts::32, p.ssrc::32,
      for(c <- csrc, into: <<>>, do: <<c::32>>)::binary, ext_bin::binary, p.payload::binary,
      pad_bin::binary>>
  end

  def encode(_), do: raise(ArgumentError, "invalid RTP packet")

  defp encode_ext(nil), do: {0, <<>>}

  defp encode_ext({id, data}) when rem(byte_size(data), 4) == 0,
    do: {1, <<id::16, div(byte_size(data), 4)::16, data::binary>>}

  @doc "Parses a packet. Returns `{:error, reason}` for malformed input."
  @spec decode(binary()) :: {:ok, t()} | {:error, atom()}
  def decode(<<2::2, p::1, x::1, cc::4, m::1, pt::7, seq::16, ts::32, ssrc::32, rest::binary>>) do
    with {:ok, csrc, rest} <- take_csrc(rest, cc),
         {:ok, ext, rest} <- take_ext(rest, x),
         {:ok, payload, pad} <- take_pad(rest, p) do
      {:ok,
       %__MODULE__{
         marker: m == 1,
         pt: pt,
         seq: seq,
         ts: ts,
         ssrc: ssrc,
         csrc: csrc,
         ext: ext,
         payload: payload,
         padding: pad
       }}
    end
  end

  def decode(<<v::2, _::bitstring>>) when v != 2, do: {:error, :bad_version}
  def decode(_), do: {:error, :truncated}

  defp take_csrc(bin, cc) do
    case bin do
      <<c::binary-size(cc * 4), rest::binary>> ->
        {:ok, for(<<v::32 <- c>>, do: v), rest}

      _ ->
        {:error, :truncated}
    end
  end

  defp take_ext(bin, 0), do: {:ok, nil, bin}

  defp take_ext(<<id::16, len::16, rest::binary>>, 1) do
    case rest do
      <<d::binary-size(len * 4), rest::binary>> -> {:ok, {id, d}, rest}
      _ -> {:error, :truncated}
    end
  end

  defp take_ext(_, 1), do: {:error, :truncated}

  defp take_pad(bin, 0), do: {:ok, bin, 0}
  defp take_pad(<<>>, 1), do: {:error, :bad_padding}

  defp take_pad(bin, 1) do
    n = :binary.last(bin)

    if n >= 1 and n <= byte_size(bin),
      do: {:ok, binary_part(bin, 0, byte_size(bin) - n), n},
      else: {:error, :bad_padding}
  end

  @doc "Adds to a 16 bit sequence number modulo 2^16."
  def seq_add(a, n), do: a + n &&& 0xFFFF

  @doc "Adds to a 32 bit timestamp modulo 2^32."
  def ts_add(a, n), do: a + n &&& 0xFFFFFFFF

  @doc "Signed distance `a - b` of sequence numbers in -32768..32767."
  def seq_diff(a, b), do: sdiff(a - b, 16)

  @doc "Signed distance `a - b` of timestamps in -2^31..2^31-1."
  def ts_diff(a, b), do: sdiff(a - b, 32)

  defp sdiff(d, bits) do
    m = 1 <<< bits
    d = d &&& m - 1
    if d >= m >>> 1, do: d - m, else: d
  end

  @doc """
  Extends a 16 bit sequence number to a monotonic integer relative to the
  previous extended value (RFC 3550 A.1 without the probation logic).

      iex> ExAes67.RTP.seq_extend(65_534, 1)
      65_537
  """
  def seq_extend(prev_ext, seq), do: prev_ext + seq_diff(seq, prev_ext &&& 0xFFFF)
end
