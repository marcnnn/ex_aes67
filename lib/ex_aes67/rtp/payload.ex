defmodule ExAes67.RTP.Payload do
  @moduledoc """
  L16 / L24 linear PCM payload (RFC 3190, big endian, channel interleaved).

  A frame is a list with one signed integer per channel. Out of range
  samples wrap. `to24/2` and `from24/2` convert to and from the 24 bit
  left-justified domain the hardware models use (L16 is shifted by 8 bits,
  `from24` truncates towards minus infinity, no dither).

      iex> alias ExAes67.RTP.Payload
      iex> bin = Payload.pack(:l24, [[1, -1], [256, -256]])
      iex> bin
      <<0, 0, 1, 255, 255, 255, 0, 1, 0, 255, 255, 0>>
      iex> Payload.unpack(:l24, bin, 2)
      {:ok, [[1, -1], [256, -256]]}
  """
  import Bitwise

  @type format :: :l16 | :l24

  @spec bytes_per_sample(format()) :: 2 | 3
  def bytes_per_sample(:l16), do: 2
  def bytes_per_sample(:l24), do: 3

  @spec pack(format(), [[integer()]]) :: binary()
  def pack(:l16, frames), do: for(f <- frames, s <- f, into: <<>>, do: <<s::signed-16>>)
  def pack(:l24, frames), do: for(f <- frames, s <- f, into: <<>>, do: <<s::signed-24>>)

  @spec unpack(format(), binary(), pos_integer()) :: {:ok, [[integer()]]} | {:error, :bad_length}
  def unpack(fmt, bin, channels) do
    if rem(byte_size(bin), channels * bytes_per_sample(fmt)) == 0 do
      samples =
        case fmt do
          :l16 -> for <<s::signed-16 <- bin>>, do: s
          :l24 -> for <<s::signed-24 <- bin>>, do: s
        end

      {:ok, Enum.chunk_every(samples, channels)}
    else
      {:error, :bad_length}
    end
  end

  @doc "Sample in native width of `fmt` to the signed 24 bit domain."
  def to24(:l16, s), do: s <<< 8
  def to24(:l24, s), do: s

  @doc "Signed 24 bit sample to the native width of `fmt` (floor)."
  def from24(:l16, s), do: s >>> 8
  def from24(:l24, s), do: s
end
