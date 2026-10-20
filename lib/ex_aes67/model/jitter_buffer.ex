defmodule ExAes67.Model.JitterBuffer do
  @moduledoc """
  Golden model of the timestamp-addressed jitter buffer.

  Storage is one slot per `{channel, ts mod depth}` holding `{ts, sample}`,
  so samples of any channel can be written in any order without
  read-modify-write. `depth` is a power of two (frames per channel).
  Timestamps are 32 bit RTP timestamps with wraparound.

  Time is the media clock in RTP timestamp units. `play(jb, now)` reads the
  frame `now - latency` and moves the window to `[ts + 1, ts + 1 + depth)`.
  A write of `ts` is checked against the window start `next`:

    * `ts < next` is `:late` (already played)
    * `ts >= next + depth` is `:overrun` (would clobber an unplayed slot)
    * a slot already holding the same `ts` is a `:duplicate`; the first copy
      wins (the hardware needs the same compare to count it)
    * a channel outside `0..channels-1` is `:bad_channel`

  A slot whose tag differs from the frame being read is an underrun for that
  channel: the sample reads as 0 and `stats.underrun` counts it.

      iex> alias ExAes67.Model.JitterBuffer, as: JB
      iex> jb = JB.new(depth: 8, channels: 2, latency: 4, now: 100)
      iex> {jb, :ok} = JB.write(jb, 0, 96, 7)
      iex> {jb, :ok} = JB.write(jb, 1, 96, -7)
      iex> {_jb, [7, -7]} = JB.play(jb, 100)
  """
  import Bitwise

  defstruct [:depth, :channels, :latency, :next, slots: %{}, stats: %{}]

  @zero %{written: 0, late: 0, overrun: 0, duplicate: 0, bad_channel: 0, underrun: 0, played: 0}

  @type result :: :ok | :late | :overrun | :duplicate | :bad_channel

  @doc "Options: `:depth` (power of two), `:channels`, `:latency` (frames, `< depth`), `:now` (media time, default 0)."
  def new(opts) do
    depth = Keyword.fetch!(opts, :depth)
    latency = Keyword.fetch!(opts, :latency)

    if depth <= 0 or (depth &&& depth - 1) != 0 or latency >= depth or latency < 0,
      do: raise(ArgumentError, "depth must be a power of two greater than latency")

    %__MODULE__{
      depth: depth,
      channels: Keyword.fetch!(opts, :channels),
      latency: latency,
      next: ts32(Keyword.get(opts, :now, 0) - latency),
      stats: @zero
    }
  end

  @spec write(%__MODULE__{}, integer(), non_neg_integer(), integer()) :: {%__MODULE__{}, result()}
  def write(%__MODULE__{} = jb, ch, ts, sample) do
    d = ts_diff(ts, jb.next)
    key = {ch, ts &&& jb.depth - 1}

    cond do
      ch < 0 or ch >= jb.channels -> {bump(jb, :bad_channel), :bad_channel}
      d < 0 -> {bump(jb, :late), :late}
      d >= jb.depth -> {bump(jb, :overrun), :overrun}
      match?({^ts, _}, jb.slots[key]) -> {bump(jb, :duplicate), :duplicate}
      true -> {bump(%{jb | slots: Map.put(jb.slots, key, {ts, sample})}, :written), :ok}
    end
  end

  @doc "Applies `{channel, ts, sample}` writes in order; returns the per-write results."
  def write_all(jb, writes) do
    Enum.map_reduce(writes, jb, fn {ch, ts, s}, jb ->
      {jb, r} = write(jb, ch, ts, s)
      {r, jb}
    end)
    |> then(fn {rs, jb} -> {jb, rs} end)
  end

  @doc "Plays the frame at media time `now`: one sample per channel."
  @spec play(%__MODULE__{}, integer()) :: {%__MODULE__{}, [integer()]}
  def play(%__MODULE__{} = jb, now) do
    ts = ts32(now - jb.latency)
    mask = jb.depth - 1

    {frame, missing} =
      Enum.map_reduce(0..(jb.channels - 1)//1, 0, fn ch, miss ->
        case jb.slots[{ch, ts &&& mask}] do
          {^ts, s} -> {s, miss}
          _ -> {0, miss + 1}
        end
      end)

    stats = %{jb.stats | underrun: jb.stats.underrun + missing, played: jb.stats.played + 1}
    {%{jb | next: ts32(ts + 1), stats: stats}, frame}
  end

  defp bump(jb, k), do: %{jb | stats: Map.update!(jb.stats, k, &(&1 + 1))}
  defp ts32(x), do: x &&& 0xFFFFFFFF
  defp ts_diff(a, b), do: ExAes67.RTP.ts_diff(a, b)
end
