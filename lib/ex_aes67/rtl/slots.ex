defmodule ExAes67.RTL.Slots do
  @moduledoc """
  Layout of the sample slot memories (jitter buffer and TX ring).

  A slot is `{valid, tag, sample24}` = `25 + tag_bits` bits. The tag is the
  low `tag_bits` of the frame timestamp; with 32 bits a slot compares equal
  exactly when the model's `{ts, sample}` slot does. Slots are packed into
  72 bit words (URAM width) when two fit, which needs `tag_bits <= 11`:
  36 bit lanes are a multiple of the URAM 9 bit write enable. Otherwise one
  slot per word.

  The word address is `{ts mod depth, channel group}`, so a frame is
  contiguous and the playout scan reads consecutive words.

      iex> s = ExAes67.RTL.Slots.new(1024, 64, 11)
      iex> {s.lane_w, s.pack, s.addr_w, s.words, s.uram}
      {36, 2, 15, 32768, 8}
      iex> s = ExAes67.RTL.Slots.new(1024, 64, 32)
      iex> {s.lane_w, s.pack, s.words, s.uram}
      {57, 1, 65536, 16}
  """
  use ExHdl.RTL
  import ExHdl.RTL.Builder, only: [ceil_log2: 1]

  defstruct [
    :channels,
    :depth,
    :tag,
    :lane_w,
    :pack,
    :idx_w,
    :grp_w,
    :addr_w,
    :words,
    :width,
    :uram
  ]

  def new(channels, depth, tag) do
    lane_w = 25 + tag
    pack = if 2 * lane_w <= 72, do: 2, else: 1
    grp_w = ceil_log2(div(channels + pack - 1, pack))
    idx_w = ceil_log2(depth)
    words = Bitwise.bsl(1, idx_w + grp_w)

    %__MODULE__{
      channels: channels,
      depth: depth,
      tag: tag,
      lane_w: lane_w,
      pack: pack,
      idx_w: idx_w,
      grp_w: grp_w,
      addr_w: idx_w + grp_w,
      words: words,
      width: pack * lane_w,
      uram: div(words + 4095, 4096) * div(pack * lane_w + 71, 72)
    }
  end

  # -- hardware helpers (expressions inside a module body) --------------------

  @doc "Word address of `{ts, ch}`: `ts` is a 32 bit, `ch` an 11 bit expression."
  def addr(%__MODULE__{} = s, ts, ch) do
    idx = trunc(ts, s.idx_w)

    cond do
      s.grp_w == 0 -> idx
      s.pack == 2 -> cat([idx, slice(ch, 1, s.grp_w)])
      true -> cat([idx, trunc(ch, s.grp_w)])
    end
  end

  @doc "The slot `{valid, tag, sample}` for `ts` and an unsigned 24 bit sample."
  def encode(%__MODULE__{} = s, ts, data), do: cat([const(1, 1), trunc(ts, s.tag), data])

  @doc "The lane of word `rd` that holds channel `ch`."
  def pick(%__MODULE__{pack: 1}, rd, _ch), do: rd

  def pick(%__MODULE__{lane_w: w}, rd, ch),
    do: mux(slice(ch, 0, 1), [slice(rd, 0, w), slice(rd, w, w)])

  @doc "`{valid, tag, sample}` fields of a slot."
  def fields(%__MODULE__{tag: t}, slot),
    do: {slice(slot, 24 + t, 1), slice(slot, 24, t), slice(slot, 0, 24)}

  @doc "Word to write (slot replicated per lane) and its lane write enables."
  def write(%__MODULE__{pack: 1}, slot, _ch), do: {slot, nil}

  def write(%__MODULE__{pack: 2}, slot, ch) do
    c0 = slice(ch, 0, 1)
    {rep(slot, 2), cat([c0, bnot_(c0)])}
  end

  defp bnot_(x), do: rtl(do: not x)
end
