defmodule ExAes67.RTL.Program do
  @moduledoc """
  Turns the stream descriptions the BEAM side already has (the maps the
  models take) into the register writes of the RTL modules.

  A write is `%{cfg_we: 1, cfg_sel: s, cfg_addr: a, cfg_data: d}`; drive them
  one per cycle on the module's `cfg_*` bus.
  """
  import Bitwise

  @doc "32 bit value of an IPv4 tuple, first octet in the MSBs."
  def ip({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d

  @doc "Bucket of `{ip, port}` in a table of `2^hash_bits` buckets (see `ExAes67.RTL.Depacketiser`)."
  def hash(ip, port, hb) when is_integer(ip) do
    x = bxor(bxor(ip >>> 16, ip &&& 0xFFFF), port)
    mask = (1 <<< hb) - 1

    0..15//hb |> Enum.reduce(0, fn i, acc -> bxor(acc, x >>> i &&& mask) end)
  end

  def hash({_, _, _, _} = ip, port, hb), do: hash(ip(ip), port, hb)

  @doc """
  RX stream table writes for `entries` (the `ExAes67.Model.Depacketiser`
  entry maps, table order = priority). Options `:streams` and `:hash_bits`
  as for the module. Returns `{writes, index}` with `index` mapping entry id
  to table index (the stats address).
  """
  def rx(entries, opts \\ []) do
    streams = Keyword.get(opts, :streams, 512)
    hb = Keyword.get(opts, :hash_bits, 10)
    idx_w = max(ExHdl.RTL.Builder.ceil_log2(streams), 1)

    if length(entries) > streams, do: raise(ArgumentError, "more entries than table slots")
    indexed = Enum.with_index(entries)
    chains = Enum.group_by(indexed, fn {e, _} -> hash(e.dst_ip, e.dst_port, hb) end)

    next =
      for {_, chain} <- chains, {{_, i}, nxt} <- Enum.zip(chain, tl(chain) ++ [nil]), into: %{} do
        {i, nxt && elem(nxt, 1)}
      end

    entry_writes =
      for {e, i} <- indexed, {data, lane} <- Enum.with_index(lanes(e, next[i], idx_w)) do
        %{cfg_we: 1, cfg_sel: 0, cfg_addr: 4 * i + lane, cfg_data: data}
      end

    heads =
      for {b, [{_, i} | _]} <- chains do
        %{cfg_we: 1, cfg_sel: 1, cfg_addr: b, cfg_data: 1 <<< idx_w ||| i}
      end

    {entry_writes ++ heads, Map.new(indexed, fn {e, i} -> {e.id, i} end)}
  end

  defp lanes(e, nxt, idx_w) do
    ssrc = e.ssrc
    fmt = if e.format == :l16, do: 1, else: 0

    [
      ip(e.dst_ip),
      e.dst_port ||| e.pt <<< 16 ||| ((ssrc && 1) || 0) <<< 23 ||| fmt <<< 24,
      ssrc || 0,
      e.channels ||| e.base_channel <<< 8 ||| (nxt || 0) <<< 18 |||
        ((nxt && 1) || 0) <<< (18 + idx_w)
    ]
  end

  @doc """
  TX stream table and state writes for `configs` (the `ExAes67.Model.Packetiser`
  stream configs, table position = stagger index). `now` is the media time at
  which the packetiser starts; every stream's first packet starts at the next
  multiple of its samples per packet, as in the model.

  A stream is disabled first and enabled by the last write, so a write
  sequence that is slower than a packet period (AXI4-Lite through clock
  domain crossings) never lets the scheduler see a half written entry.
  """
  def tx(configs, now \\ 0) do
    lanes = for {c, i} <- Enum.with_index(configs), do: {i, tx_lanes(c, i)}
    lane = fn i, l, data -> %{cfg_we: 1, cfg_sel: 0, cfg_addr: 8 * i + l, cfg_data: data} end

    disable = for {i, [_, l1 | _]} <- lanes, do: lane.(i, 1, l1 &&& bnot(1 <<< 24))

    cfg_writes =
      for {i, ls} <- lanes, {data, l} <- Enum.with_index(ls), l != 1, do: lane.(i, l, data)

    enable = for {i, [_, l1 | _]} <- lanes, do: lane.(i, 1, l1)

    state_writes =
      for {c, i} <- Enum.with_index(configs),
          {data, lane} <- Enum.with_index([tx_start(c, now), Map.get(c, :seq0, 0)]) do
        %{cfg_we: 1, cfg_sel: 1, cfg_addr: 2 * i + lane, cfg_data: data}
      end

    disable ++ cfg_writes ++ state_writes ++ enable
  end

  defp spp(c) do
    rate = Map.get(c, :rate, 48_000)
    div(c.ptime_us * rate, 1_000_000)
  end

  defp tx_start(c, now), do: div(now + spp(c) - 1, spp(c)) * spp(c) &&& 0xFFFFFFFF

  defp tx_lanes(c, i) do
    spp = spp(c)
    fmt = if c.format == :l16, do: 1, else: 0

    [
      ip(c.dst_ip),
      c.dst_port ||| c.pt <<< 16 ||| fmt <<< 23 ||| 1 <<< 24,
      c.ssrc,
      Map.get(c, :ts_offset, 0),
      c.channels ||| c.base_channel <<< 8 ||| spp <<< 18,
      spp + rem(i, spp)
    ]
  end
end
