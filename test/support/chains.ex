defmodule ExAes67.Test.Chains do
  @moduledoc false
  # Top levels that wire ex_net, ex_ptp and ex_aes67 together for the integration tests.
  use ExHdl.RTL
  alias ExHdl.RTL.Module
  alias ExAes67.RTL.{Packetiser, Rx}
  alias ExNet.RTL.{Classifier, Ifc, MacTx, RxPath, TxPath}
  alias ExPtp.RTL.{MediaNco, RxStamp, TimestampUnit, TxInsert, Wallclock}

  @doc "Nominal wallclock increment (2^-32 ns) for `cycles` clock cycles per 48 kHz sample."
  def wc_inc(cycles), do: round(1.0e9 / (48_000 * cycles) * 4_294_967_296)

  @doc """
  Receive chain on one clock: XGMII -> `RxPath` (MAC RX, classifier, UDP payload extractor)
  -> `Rx` (depacketiser, jitter buffer); the frame stream also goes through `RxStamp`
  with the `TimestampUnit` (MAC clock = system clock here), a wallclock and `MediaNco`
  whose `{tick, rtp_ts}` drive the jitter buffer.

  Inputs: `xgmii_rxd/rxc`, `cls_cfg_*` (classifier table), `dp_cfg_*`, `dp_stat_*`
  (depacketiser), `latency`, wallclock `set_wr/set_sec/set_ns`, `rx_comp`, `stamp_tready`,
  `mc_offset`, `align`. Outputs: everything of `Rx`, `stamp_*` (the `RxStamp` stream),
  `nco_*`, `now_*`, and `stamp_stall` (a frame beat the stamp stage could not take).
  """
  def rx_chain(opts) do
    cycles = Keyword.fetch!(opts, :tick_cycles)
    entries = Keyword.get(opts, :entries, 4)
    sb = 4
    inc = wc_inc(cycles)

    rx_mod =
      Rx.build(
        streams: Keyword.get(opts, :streams, 8),
        hash_bits: Keyword.get(opts, :hash_bits, 3),
        bank_words: Keyword.get(opts, :bank_words, 64),
        channels: Keyword.fetch!(opts, :channels),
        depth: Keyword.fetch!(opts, :depth),
        tag_bits: 32
      )

    module "rx_chain_c#{cycles}_n#{entries}" do
      rxd = input(:xgmii_rxd, 64)
      rxc = input(:xgmii_rxc, 8)
      cls_we = input(:cls_cfg_we, 1)
      cls_addr = input(:cls_cfg_addr, Classifier.addr_width(entries))
      cls_data = input(:cls_cfg_data, 32)
      set_wr = input(:set_wr, 1)
      set_sec = input(:set_sec, 48)
      set_ns = input(:set_ns, 30)
      rx_comp = input(:rx_comp, 32)
      align = input(:align, 1)
      offset = input(:mc_offset, 32)

      path =
        instance(:u_path, RxPath.build(entries: entries, stream_bits: sb, depth: 128),
          connect: [
            xgmii_rxd: rxd,
            xgmii_rxc: rxc,
            cfg_we: cls_we,
            cfg_addr: cls_addr,
            cfg_data: cls_data
          ]
        )

      wc = instance(:wc, Wallclock.build(ncap: 0, snap: false, pps: false, nominal: inc))
      wc.set_wr <~ set_wr
      wc.set_sec <~ set_sec
      wc.set_ns <~ set_ns
      for p <- ~w(inc_wr step_wr slew_wr)a, do: wc[p] <~ 0
      for {p, w} <- [inc_in: 40, slew_r: 32, slew_ticks: 32], do: wc[p] <~ const(0, u(w))
      wc.step_ns <~ const(0, s(30))
      wc.slew_q <~ const(0, s(64))

      tsu =
        instance(:tsu, TimestampUnit.build(),
          domains: [mac: :sys],
          connect: [
            rx_sof: path.rx.sof,
            tx_sof: const(0, 1),
            tx_tag: const(0, 8),
            now_sec: wc.now_sec,
            now_ns: wc.now_ns,
            now_frac: wc.now_frac,
            rx_comp: rx_comp,
            tx_comp: const(0, 32),
            tx_pop: const(0, 1)
          ]
        )

      stamp = instance(:stamp, RxStamp.build(64))
      for f <- [:tdata, :tkeep, :tlast, :tuser, :tvalid], do: stamp.s_axis[f] <~ path.frame[f]
      stamp.ts_valid <~ tsu.rx_valid
      stamp.ts <~ tsu.rx_ts
      sm = master(:stamp, Interface.axi_stream(data: 64, user: 102))
      connect(stamp.m_axis, sm)
      output(:stamp_stall, 1) <~ (path.frame.tvalid and not stamp.s_axis.tready)
      output(:no_ts, 1) <~ stamp.no_ts
      output(:ts_overflow, 1) <~ stamp.ts_overflow

      nco =
        instance(:nco, MediaNco.build(),
          connect: [
            now_sec: wc.now_sec,
            now_ns: wc.now_ns,
            now_frac: wc.now_frac,
            rate: const(48_000, 18),
            offset: offset,
            inc_wr: const(0, 1),
            inc_in: const(0, 64),
            follow: const(1, 1),
            wc_inc: const(inc, 40),
            kscale: const(MediaNco.kscale(48_000), 56),
            align: align
          ]
        )

      # the jitter buffer starts with the first tick after the media clock was aligned
      run = reg(:jb_run, 1)

      sync do
        if nco.aligned, do: run <~ 1
      end

      rx = instance(:rx, rx_mod)
      connect(path.m_axis, rx.s_axis)
      rx.tick <~ (nco.tick and run)
      rx.rtp_ts <~ nco.rtp_ts
      output(:jb_tick, 1) <~ (nco.tick and run)

      for p <- Module.data_inputs(rx_mod),
          not String.starts_with?(Atom.to_string(p.name), "s_axis"),
          p.name not in [:tick, :rtp_ts] do
        name = if p.name == :latency, do: :latency, else: :"dp_#{p.name}"
        rx[p.name] <~ input(name, p.type)
      end

      for p <- Module.outputs(rx_mod), do: output(p.name, p.type) <~ rx[p.name]
      output(:now_sec, 48) <~ wc.now_sec
      output(:now_ns, 32) <~ wc.now_ns
      output(:now_frac, 32) <~ wc.now_frac
      output(:tick, 1) <~ nco.tick
      output(:rtp_ts, 32) <~ nco.rtp_ts
      output(:mc_mclk_en, 1) <~ nco.mclk_en
      output(:mc_phase, 64) <~ nco.phase
      output(:mc_busy, 1) <~ nco.busy
      output(:aligned, 1) <~ nco.aligned
      output(:p_frame_end, 1) <~ path.frame_end
      output(:p_status, 3) <~ path.status
      output(:p_ovf, 1) <~ path.ovf
      output(:p_drop_bad, 1) <~ path.drop_bad
      output(:p_drop_full, 1) <~ path.drop_full
      output(:p_level, 8) <~ path.level
      output(:p_dbg, 2) <~ path.dbg
      output(:t_tx_valid, 1) <~ tsu.tx_ts_valid
      output(:t_tx_tag, 8) <~ tsu.tx_ts_tag
      output(:t_tx_ts, 94) <~ tsu.tx_ts
      output(:t_tx_overflow, 1) <~ tsu.tx_overflow
      output(:wc_busy, 1) <~ wc.slew_busy
    end
  end

  @doc """
  Transmit chain on one clock: `Packetiser` (RTP, media clock from `MediaNco`, gated by
  `pk_go`) and a testbench UDP source `s1_axis_*` (PTP payloads) -> `TxPath` (`UdpTx`, packet
  FIFOs, merge) -> `TxInsert` (one-step Sync) -> `MacTx` -> XGMII, with the MAC's `tx_sof` and
  `tx_tag` into the `TimestampUnit` (wallclock on the same clock).

  Inputs: `k_*` (packetiser `cfg_*`, `in_*`), `pk_go`, `s1_axis_*`, `src_mac`, `src_ip`, `uc_mac`,
  `s0_*` / `s1_*` (`src_port`, `ttl`, `tos`, `tag` of the two sources), `x_enable`,
  `x_zero_csum`, `x_comp`, `tx_comp`, `tx_pop`, wallclock `set_*`, `align`, `mc_offset`.
  Outputs: `xgmii_txd/txc`, `tx_sof`, `tx_tag`, the unit's `tx_ts_*`, `now_*`, `tick`,
  `rtp_ts`, `st_*` of the packetiser, `drop`, `stamped`.
  """
  def tx_chain(opts) do
    cycles = Keyword.fetch!(opts, :tick_cycles)
    inc = wc_inc(cycles)

    pk_mod =
      Packetiser.build(
        streams: Keyword.get(opts, :streams, 4),
        channels: Keyword.fetch!(opts, :channels),
        depth: Keyword.fetch!(opts, :depth),
        tag_bits: 32
      )

    module "tx_chain_c#{cycles}" do
      src_mac = input(:src_mac, 48)
      src_ip = input(:src_ip, 32)
      uc_mac = input(:uc_mac, 48)
      set_wr = input(:set_wr, 1)
      set_sec = input(:set_sec, 48)
      set_ns = input(:set_ns, 30)
      align = input(:align, 1)
      offset = input(:mc_offset, 32)
      go = input(:pk_go, 1)
      ins_enable = input(:x_enable, 1)
      ins_zero = input(:x_zero_csum, 1)
      ins_comp = input(:x_comp, 32)
      tx_comp = input(:tx_comp, 32)
      tx_pop = input(:tx_pop, 1)

      s1 = slave(:s1_axis, Ifc.udp_tx())

      path_in =
        for i <- 0..1, {k, w} <- [src_port: 16, ttl: 8, tos: 8, tag: 8] do
          {:"s#{i}_#{k}", input(:"s#{i}_#{k}", w)}
        end

      path =
        instance(:path, TxPath.build(sources: 2, depth: 256),
          connect: [src_mac: src_mac, src_ip: src_ip, uc_mac: uc_mac] ++ path_in
        )

      pk = instance(:pk, pk_mod)
      connect(pk.m_axis, path.s0_axis)
      connect(s1, path.s1_axis)

      for p <- Module.data_inputs(pk_mod),
          p.name not in [:tick, :rtp_ts],
          not String.starts_with?(Atom.to_string(p.name), "m_axis") do
        pk[p.name] <~ input(:"k_#{p.name}", p.type)
      end

      wc = instance(:wc, Wallclock.build(ncap: 0, snap: false, pps: false, nominal: inc))
      wc.set_wr <~ set_wr
      wc.set_sec <~ set_sec
      wc.set_ns <~ set_ns
      for p <- ~w(inc_wr step_wr slew_wr)a, do: wc[p] <~ 0
      for {p, w} <- [inc_in: 40, slew_r: 32, slew_ticks: 32], do: wc[p] <~ const(0, u(w))
      wc.step_ns <~ const(0, s(30))
      wc.slew_q <~ const(0, s(64))

      nco =
        instance(:nco, MediaNco.build(),
          connect: [
            now_sec: wc.now_sec,
            now_ns: wc.now_ns,
            now_frac: wc.now_frac,
            rate: const(48_000, 18),
            offset: offset,
            inc_wr: const(0, 1),
            inc_in: const(0, 64),
            follow: const(1, 1),
            wc_inc: const(inc, 40),
            kscale: const(MediaNco.kscale(48_000), 56),
            align: align
          ]
        )

      pk.tick <~ (nco.tick and go)
      pk.rtp_ts <~ nco.rtp_ts

      ins =
        instance(:ins, TxInsert.build(64),
          connect: [
            enable: ins_enable,
            zero_csum: ins_zero,
            comp: ins_comp,
            now_sec: wc.now_sec,
            now_ns: wc.now_ns,
            now_frac: wc.now_frac
          ]
        )

      mac = instance(:mac, MacTx.build(64))
      connect(path.m_axis, ins.s_axis)
      connect(ins.m_axis, mac.s_axis)

      tsu =
        instance(:tsu, TimestampUnit.build(),
          domains: [mac: :sys],
          connect: [
            rx_sof: const(0, 1),
            tx_sof: mac.tx_sof,
            tx_tag: mac.tx_tag,
            now_sec: wc.now_sec,
            now_ns: wc.now_ns,
            now_frac: wc.now_frac,
            rx_comp: const(0, 32),
            tx_comp: tx_comp,
            tx_pop: tx_pop
          ]
        )

      output(:xgmii_txd, 64) <~ mac.xgmii_txd
      output(:xgmii_txc, 8) <~ mac.xgmii_txc
      output(:tx_sof, 1) <~ mac.tx_sof
      output(:tx_tag, 8) <~ mac.tx_tag
      output(:stamped, 1) <~ ins.stamped
      output(:drop, 2) <~ path.drop
      output(:lvl0, 9) <~ path.s0_level
      output(:lvl1, 9) <~ path.s1_level
      output(:ts_valid, 1) <~ tsu.tx_ts_valid
      output(:ts_tag, 8) <~ tsu.tx_ts_tag
      output(:ts_ts, 94) <~ tsu.tx_ts
      output(:ts_overflow, 1) <~ tsu.tx_overflow
      output(:rxts_valid, 1) <~ tsu.rx_valid
      output(:rxts_ts, 94) <~ tsu.rx_ts
      output(:now_sec, 48) <~ wc.now_sec
      output(:now_ns, 32) <~ wc.now_ns
      output(:now_frac, 32) <~ wc.now_frac
      output(:tick, 1) <~ nco.tick
      output(:rtp_ts, 32) <~ nco.rtp_ts
      output(:mc_mclk_en, 1) <~ nco.mclk_en
      output(:mc_phase, 64) <~ nco.phase
      output(:mc_busy, 1) <~ nco.busy
      output(:aligned, 1) <~ nco.aligned
      output(:wc_busy, 1) <~ wc.slew_busy

      for p <- Module.outputs(pk_mod),
          not String.starts_with?(Atom.to_string(p.name), "m_axis"),
          do: output(p.name, p.type) <~ pk[p.name]
    end
  end
end
