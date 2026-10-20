defmodule ExAes67.Model.SampleRing do
  @moduledoc """
  Model of the transmit history ring: `depth` frames (power of two) per
  channel, addressed by media time. A read returns `{:ok, sample}` only when
  the slot is tagged with the requested time, else `:stale`.

      iex> alias ExAes67.Model.SampleRing, as: R
      iex> r = R.new(depth: 4) |> R.write(0, 10, 5)
      iex> {R.read(r, 0, 10), R.read(r, 0, 14), R.read(r, 1, 10)}
      {{:ok, 5}, :stale, :stale}
  """
  import Bitwise

  defstruct [:depth, slots: %{}]

  def new(opts) do
    depth = Keyword.fetch!(opts, :depth)

    if depth <= 0 or (depth &&& depth - 1) != 0,
      do: raise(ArgumentError, "depth must be a power of two")

    %__MODULE__{depth: depth}
  end

  def write(%__MODULE__{} = r, ch, ts, sample),
    do: %{r | slots: Map.put(r.slots, {ch, ts &&& r.depth - 1}, {ts, sample})}

  def read(%__MODULE__{} = r, ch, ts) do
    case r.slots[{ch, ts &&& r.depth - 1}] do
      {^ts, s} -> {:ok, s}
      _ -> :stale
    end
  end
end
