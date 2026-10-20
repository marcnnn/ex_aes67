defmodule ExAes67.RTL.Rx do
  @moduledoc """
  Receive path: `ExAes67.RTL.Depacketiser` feeding `ExAes67.RTL.JitterBuffer`.

  Ports are those of the two modules with these names: the stream
  `s_axis_*`, the depacketiser table bus `cfg_*` and `stat_*`, the media clock
  `tick`, `rtp_ts` and `latency`, the TDM playout `out_*`, the depacketiser
  counters as `rx_<name>` and the jitter buffer counters as `jb_<name>`.

  Options: `:streams`, `:hash_bits`, `:bank_words` for the depacketiser,
  `:channels`, `:depth`, `:tag_bits`, `:style` for the jitter buffer.
  """
  use ExHdl.RTL
  alias ExAes67.RTL.{Depacketiser, Interfaces, JitterBuffer}

  def build(opts \\ []) do
    dp_mod = Depacketiser.build(Keyword.take(opts, [:streams, :hash_bits, :bank_words]))
    jb_mod = JitterBuffer.build(Keyword.take(opts, [:channels, :depth, :tag_bits, :style]))

    lat_w =
      jb_mod
      |> ExHdl.RTL.Module.data_inputs()
      |> Enum.find(&(&1.name == :latency))
      |> then(& &1.type)

    suffix = String.replace_prefix(jb_mod.name, "aes67_jb_", "")

    module "aes67_rx_#{String.replace_prefix(dp_mod.name, "aes67_depack_", "")}_#{suffix}" do
      s = slave(:s_axis, Interfaces.udp_rx())
      dp = instance(:dp, dp_mod)
      jb = instance(:jb, jb_mod)
      connect(s, dp.s_axis)

      for {p, w} <- [cfg_we: 1, cfg_sel: 2, cfg_addr: 16, cfg_data: 32, stat_lane: 3] do
        dp[p] <~ input(p, w)
      end

      {_, aw} = Enum.find(dp_mod.ports, &(&1.name == :stat_addr)).type
      dp.stat_addr <~ input(:stat_addr, aw)
      output(:stat_data, 32) <~ dp.stat_data

      jb.wr_valid <~ dp.wr_valid
      dp.wr_ready <~ jb.wr_ready
      jb.wr_ch <~ dp.wr_ch
      jb.wr_ts <~ dp.wr_ts
      jb.wr_data <~ dp.wr_data

      jb.tick <~ input(:tick, 1)
      jb.rtp_ts <~ input(:rtp_ts, 32)
      jb.latency <~ input(:latency, elem(lat_w, 1))

      for {p, w} <- [out_valid: 1, out_ch: 10, out_data: s(24), out_first: 1, out_last: 1] do
        output(p, w) <~ jb[p]
      end

      for k <- Depacketiser.stats(), do: output(:"rx_#{k}", 32) <~ dp[:"st_#{k}"]
      for k <- JitterBuffer.stats(), do: output(:"jb_#{k}", 32) <~ jb[:"st_#{k}"]
    end
  end
end
