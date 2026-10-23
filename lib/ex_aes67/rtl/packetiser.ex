defmodule ExAes67.RTL.Packetiser do
  @moduledoc """
  RTP transmit packetiser, the RTL of `ExAes67.Model.Packetiser` with
  `ExAes67.Model.SampleRing`.

  ## Data flow

    * A TDM source writes one sample per cycle (`in_valid`, `in_ch`, `in_data`)
      into the sample ring after each tick, tagged with the media time of
      that tick. The ring is the model's `SampleRing`: slots `{valid, tag,
      sample}` addressed by `{ts mod depth, channel}` (`ExAes67.RTL.Slots`);
      a slot with the wrong tag is silence and counts in `st_silence`.
    * On every tick a scheduler scans the stream table, one stream per cycle.
      A stream is due when `now - (start + dly) >= 0` (signed 32 bit) where
      `start` is the media time of its next packet's first frame and
      `dly = spp + stagger`, which is the model's `start + spp + (i mod spp)`.
      `start` and the sequence number live in a state RAM and are
      advanced after each packet.
    * A due stream is built right away: 12 byte RTP header, then
      `spp * channels` samples read from the ring frame-major, packed into
      64 bit beats (L24: three bytes, L16: the top 16 bits), as an AXI4-Stream
      UDP payload (`ExAes67.RTL.Interfaces.udp_tx/0`, `tuser` constant over the
      packet). Then the scan continues.

  The bytes are those of `ExAes67.RTP.encode/1` (version 2, no padding,
  extension, CSRC or marker).

  ## Ports (clock `clk`, reset `rst_n`)

  | Port | Meaning |
  |---|---|
  | `tick`, `rtp_ts` (32) | media clock, see `ExAes67.RTL.Interfaces`; samples for the frame of a tick are written from the cycle after it |
  | `in_valid`, `in_ch` (11), `in_data` (s24) | TDM sample input, always accepted |
  | `m_axis_*` | master, `udp_tx/0` |
  | `cfg_we`, `cfg_sel` (2), `cfg_addr` (16), `cfg_data` (32) | table write bus |
  | `st_packets`, `st_silence`, `st_late`, `st_sched_overrun` | 32 bit counters |

  ## Tables

  `cfg_sel = 0`: stream `i` is eight 32 bit lanes at `cfg_addr = 8 i + lane`:

  | Lane | Bits |
  |---|---|
  | 0 | destination IP |
  | 1 | `[15:0]` port, `[22:16]` payload type, `[23]` 1 = L16, `[24]` enable |
  | 2 | SSRC |
  | 3 | `mediaclk:direct` offset (added to the media time for the RTP timestamp) |
  | 4 | `[7:0]` channels, `[17:8]` base channel in the ring, `[26:18]` samples per packet |
  | 5 | `[9:0]` `spp + stagger` |

  `cfg_sel = 1`: state of stream `i`, `cfg_addr = 2 i + lane`: lane 0 first
  packet start (media time, a multiple of `spp`), lane 1 sequence number.
  `ExAes67.RTL.Program.tx/2` produces both from the model's stream configs.

  ## Timing

  A scan takes one cycle per table slot (`streams`). A packet costs about 8
  cycles plus one per sample (measured: 57 cycles from the tick to the last
  beat for 48 samples), a beat leaves every 2.67 samples in L24. At 156.25
  MHz a sample period is 3255 cycles: 1024 single channel streams of 1 ms
  need `1024 + 21.3 * 56` (68%), 128 eight channel streams `128 + 2.7 *
  392` (36%), 1024 single channel streams of 125 us `1024 + 171 * 14` (105%:
  use 250 MHz or fewer streams). Ticks that arrive while a scan or build is
  running are remembered once (`st_sched_overrun`); streams that are late are
  served in the next scan, so a stream is never skipped, it is `st_late`. The
  model's `max_per_tick` drop is replaced by this lateness. At most one packet
  per stream per scan.

  The ring must hold the frames of a packet plus the stagger:
  `depth > spp + stagger + 1` for the longest stream.
  """
  use ExHdl.RTL
  import Bitwise, only: [bsl: 2]
  import ExHdl.RTL.Builder, only: [ceil_log2: 1]
  alias ExAes67.RTL.{Interfaces, Slots}

  @idle 0
  @scan 1
  @setup 2
  @hdr 3
  @run 4
  @flush 5
  @fin 6

  @stats ~w(packets silence late sched_overrun)a
  def stats, do: @stats

  @doc "Options: `:streams` (512), `:channels` (1024), `:depth` (128), `:tag_bits` (32), `:style` (`:block`)."
  def build(opts \\ []) do
    streams = Keyword.get(opts, :streams, 512)
    n = Keyword.get(opts, :channels, 1024)
    depth = Keyword.get(opts, :depth, 128)
    tag = Keyword.get(opts, :tag_bits, 32)
    style = Keyword.get(opts, :style, :block)
    idx_w = max(ceil_log2(streams), 1)
    sl = Slots.new(n, depth, tag)
    name = "aes67_pack_#{streams}_#{n}x#{depth}_t#{tag}_#{style}"

    module name do
      %{tick: tick, rtp_ts: rtp_ts} = ExPtp.RTL.Ifc.media_clock(:slave)
      in_valid = input(:in_valid, 1)
      in_ch = input(:in_ch, 11)
      in_data = input(:in_data, s(24))
      m = master(:m_axis, Interfaces.udp_tx())
      cfg_we = input(:cfg_we, 1)
      cfg_sel = input(:cfg_sel, 2)
      cfg_addr = input(:cfg_addr, 16)
      cfg_data = input(:cfg_data, 32)
      st = for k <- @stats, into: %{}, do: {k, output(:"st_#{k}", 32, reset: 0)}

      cfgm = memory(:streamcfg, width: 256, depth: streams, byte: 32)
      stm = memory(:streamstate, width: 64, depth: streams, byte: 32)
      ring = memory(:ring, width: sl.width, depth: sl.words, style: style, byte: sl.lane_w)

      pst = reg(:pst, 3)
      s1_idx = reg(:s1_idx, idx_w)
      s1v = reg(:s1v, 1)
      ptr = reg(:ptr, idx_w + 1)
      now = reg(:now, 32)
      pend = reg(:pend, 1)
      frame_ts = reg(:frame_ts, 32)

      # -- host writes and ring input --------------------------------------------------------
      be8 = mux(slice(cfg_addr, 0, 3), for(k <- 0..7, do: const(bsl(1, k), 8)))

      write_port(cfgm,
        addr: slice(cfg_addr, 3, idx_w),
        data: rep(cfg_data, 8),
        en: cfg_we and cfg_sel == 0,
        be: be8
      )

      {rword, rbe} = Slots.write(sl, Slots.encode(sl, frame_ts, as_unsigned(in_data)), in_ch)
      write_port(ring, addr: Slots.addr(sl, frame_ts, in_ch), data: rword, en: in_valid, be: rbe)

      # -- stream table scan -------------------------------------------------------------------
      # `issue` is defined below (it depends on the data read with it)
      issue = wire(:issue, 1)
      cfg_rd = read_port(cfgm, addr: trunc(ptr, idx_w), en: issue, name: :cfg_rd)
      st_rd = read_port(stm, addr: trunc(ptr, idx_w), en: issue, name: :st_rd)

      e_ip = slice(cfg_rd, 0, 32)
      e_port = slice(cfg_rd, 32, 16)
      e_pt = slice(cfg_rd, 48, 7)
      e_fmt = slice(cfg_rd, 55, 1)
      e_en = slice(cfg_rd, 56, 1)
      e_ssrc = slice(cfg_rd, 64, 32)
      e_toff = slice(cfg_rd, 96, 32)
      e_ch = slice(cfg_rd, 128, 8)
      e_base = slice(cfg_rd, 136, 10)
      e_spp = slice(cfg_rd, 146, 9)
      e_dly = slice(cfg_rd, 160, 10)
      start = slice(st_rd, 0, 32)
      seq = slice(st_rd, 32, 16)

      diff = wire(:diff, as_signed(sub_wrap(now, add_wrap(start, zext(e_dly, 32)))))
      due = wire(:due, s1v and e_en == 1 and diff >= 0)
      issue <~ (scanning_(pst) and ptr < streams and not due)

      # -- output register ----------------------------------------------------------------------
      o_valid = reg(:o_valid, 1)
      o_data = reg(:o_data, 64, reset: nil)
      o_keep = reg(:o_keep, 8, reset: nil)
      o_last = reg(:o_last, 1, reset: nil)
      o_user = reg(:o_user, 64, reset: nil)
      m.tvalid <~ o_valid
      m.tdata <~ o_data
      m.tkeep <~ o_keep
      m.tlast <~ o_last
      m.tuser <~ o_user
      adv = wire(:adv, not o_valid or m.tready)

      total = reg(:total, 16, reset: nil)
      left = reg(:left, 16, reset: nil)

      emit = fn data, keep, last ->
        o_valid <~ 1
        o_data <~ data
        o_keep <~ keep
        o_last <~ last
        o_user <~ cat([total, e_port, e_ip])
      end

      # -- sample pipeline: A issues ring reads, B packs bytes ----------------------------------
      fa = reg(:fa, 9, reset: nil)
      ca = reg(:ca, 8, reset: nil)
      a_run = reg(:a_run, 1)
      b_v = reg(:b_v, 1)
      b_ch = reg(:b_ch, 11, reset: nil)
      b_ts = reg(:b_ts, 32, reset: nil)
      acc = reg(:acc, 88, reset: nil)
      accn = reg(:accn, 3, reset: nil)

      ts_a = wire(:ts_a, add_wrap(start, zext(fa, 32)))
      ch_a = wire(:ch_a, add_wrap(zext(e_base, 11), zext(ca, 11)))
      run = wire(:run, pst == @run)

      ring_rd =
        read_port(ring,
          addr: Slots.addr(sl, ts_a, ch_a),
          en: run and adv and a_run,
          name: :ring_rd
        )

      {bv, btag, bdata} = Slots.fields(sl, Slots.pick(sl, ring_rd, b_ch))
      hit = wire(:hit, bv == 1 and btag == trunc(b_ts, tag))
      sm = wire(:sm, mux(hit, bdata, 0))
      vec24 = cat([slice(sm, 0, 8), slice(sm, 8, 8), slice(sm, 16, 8)])
      vec16 = zext(cat([slice(sm, 8, 8), slice(sm, 16, 8)]), 24)
      vec = wire(:vec, mux(e_fmt, vec16, vec24))
      nb = wire(:nb, mux(e_fmt, const(2, 4), const(3, 4)))
      shifted = for k <- 0..7, do: trunc(zext(vec, 88) <<< (8 * k), 88)
      new_acc = wire(:new_acc, acc ||| mux(accn, shifted))
      total_n = wire(:total_n, zext(accn, 4) + nb)
      step = wire(:step, run and adv and b_v)
      full = wire(:full, step and total_n >= 8)

      # -- state RAM: one write port shared by the host and the end of a packet ---------------------
      fin = wire(:fin, pst == @fin)
      fin_word = cat([zext(add_wrap(seq, 1), 32), add_wrap(start, zext(e_spp, 32))])
      host = wire(:host, cfg_we and cfg_sel == 1)
      host_be = mux(slice(cfg_addr, 0, 1), [const(1, 2), const(2, 2)])

      write_port(stm,
        addr: mux(fin, s1_idx, slice(cfg_addr, 1, idx_w)),
        data: mux(fin, fin_word, rep(cfg_data, 2)),
        en: fin or host,
        be: mux(fin, const(3, 2), host_be)
      )

      pay1 = wire(:pay1, e_spp * e_ch)
      pay = wire(:pay, mux(e_fmt, cat([pay1, const(0, 1)]), pay1 + cat([pay1, const(0, 1)])))
      ts = wire(:ts, add_wrap(start, e_toff))

      hdr =
        cat([
          bswap(ts),
          cat([slice(seq, 0, 8), slice(seq, 8, 8)]),
          cat([const(0, 1), e_pt]),
          const(0x80, 8)
        ])

      scan_done = wire(:scan_done, scanning_(pst) and ptr == streams and not s1v)

      sync do
        frame_ts_update(tick, frame_ts, rtp_ts)
        if o_valid and m.tready, do: o_valid <~ 0

        if tick do
          now <~ rtp_ts
          pend <~ 1
          if pst != @idle or pend == 1, do: st.sched_overrun <~ add_wrap(st.sched_overrun, 1)
        end

        if issue do
          s1v <~ 1
          s1_idx <~ trunc(ptr, idx_w)
          ptr <~ add_wrap(ptr, 1)
        else
          if scanning_(pst) and not due, do: s1v <~ 0
        end

        switch pst do
          @idle ->
            if pend == 1 do
              if not tick, do: pend <~ 0
              ptr <~ 0
              s1v <~ 0
              pst <~ @scan
            end

          @scan ->
            if due do
              if diff > 0, do: st.late <~ add_wrap(st.late, 1)
              pst <~ @setup
            else
              if scan_done, do: pst <~ @idle
            end

          @setup ->
            total <~ trunc(pay + 12, 16)
            left <~ trunc(pay + 12, 16)
            fa <~ 0
            ca <~ 0
            a_run <~ 1
            b_v <~ 0
            pst <~ @hdr

          @hdr ->
            if adv do
              emit.(hdr, const(0xFF, 8), const(0, 1))
              acc <~ zext(bswap(e_ssrc), 88)
              accn <~ 4
              left <~ sub_wrap(left, 8)
              pst <~ @run
            end

          @run ->
            if adv do
              if a_run do
                b_v <~ 1
                b_ch <~ ch_a
                b_ts <~ ts_a

                if ca == sub_wrap(e_ch, 1) do
                  ca <~ 0
                  fa <~ add_wrap(fa, 1)
                  if fa == sub_wrap(e_spp, 1), do: a_run <~ 0
                else
                  ca <~ add_wrap(ca, 1)
                end
              else
                b_v <~ 0
              end
            end

            if step do
              if not hit, do: st.silence <~ add_wrap(st.silence, 1)

              if full do
                emit.(slice(new_acc, 0, 64), const(0xFF, 8), left == 8)
                acc <~ zext(slice(new_acc, 64, 24), 88)
                accn <~ trunc(sub_wrap(total_n, 8), 3)
                left <~ sub_wrap(left, 8)
              else
                acc <~ new_acc
                accn <~ trunc(total_n, 3)
              end
            end

            if not a_run and not b_v, do: pst <~ @flush

          @flush ->
            if left == 0 do
              pst <~ @fin
            else
              if adv do
                emit.(
                  slice(acc, 0, 64),
                  mux(trunc(left, 3), [0, 1, 3, 7, 15, 31, 63, 127] |> Enum.map(&const(&1, 8))),
                  const(1, 1)
                )

                pst <~ @fin
              end
            end

          @fin ->
            st.packets <~ add_wrap(st.packets, 1)
            s1v <~ 0
            pst <~ @scan

          _ ->
            pst <~ @idle
        end
      end
    end
  end

  defp scanning_(pst), do: rtl(do: pst == @scan)
  defp frame_ts_update(tick, frame_ts, rtp_ts), do: rtl(do: if(tick, do: frame_ts <~ rtp_ts))

  defp bswap(x) do
    n = div(ExHdl.RTL.Expr.width(x), 8)
    ExHdl.RTL.Expr.cat(for i <- 0..(n - 1), do: ExHdl.RTL.Expr.slice(x, i * 8, 8))
  end
end
