defmodule ExAes67.RTL.Depacketiser do
  @moduledoc """
  RTP receive depacketiser, the RTL of `ExAes67.Model.Depacketiser`.

  A UDP payload stream (64 bit AXI4-Stream, byte 0 in `tdata[7:0]`) is stored
  in a two bank packet buffer (store and forward: a bad packet never writes a
  sample, as in the model). While one packet drains, the next one is received.
  The drain engine parses the RTP header (already captured on receive),
  looks the stream up, updates the stream stats and then emits one
  `{channel, rtp_ts, sample24}` write per sample, frame-major like the model,
  through a ready/valid port (`wr_*`, same signals as the `ExAes67.RTL.JitterBuffer` write port).

  ## Ports (clock `clk`, reset `rst_n`)

  | Port | Meaning |
  |---|---|
  | `s_axis_*` | slave, `ExAes67.RTL.Interfaces.udp_rx/0`: 64 bit data, `tkeep`, `tlast`, `tuser` (96, valid on the first beat) |
  | `cfg_we`, `cfg_sel` (2), `cfg_addr` (16), `cfg_data` (32) | table write bus, see below |
  | `stat_addr`, `stat_lane` (3), `stat_data` (32) | per stream counters, one cycle read latency |
  | `wr_valid`, `wr_ready`, `wr_ch` (11), `wr_ts` (32), `wr_data` (s24) | sample writes |
  | `st_ok`, `st_bad_rtp`, `st_no_stream`, `st_bad_length` | 32 bit global counters (`st_ok` counts accepted packets) |

  ## Stream table

  Entry `i` (0 .. `streams - 1`) is four 32 bit words written at `cfg_sel = 0`,
  `cfg_addr = 4 i + lane`:

  | Lane | Bits |
  |---|---|
  | 0 | destination IP, first octet in the MSBs |
  | 1 | `[15:0]` port, `[22:16]` payload type, `[23]` match SSRC, `[24]` 1 = L16 |
  | 2 | SSRC |
  | 3 | `[7:0]` channels, `[17:8]` base channel, `[18 + idx_w - 1 : 18]` next entry of the chain, bit `18 + idx_w` next valid |

  Lookup is a hash table (`cfg_sel = 1`, `cfg_addr` = bucket, `cfg_data` =
  `{valid, head index}`) of chains: the bucket is the 16 bit fold
  `ip[31:16] ^ ip[15:0] ^ port` XOR-folded to `hash_bits`. A chain is walked entry by
  entry (two cycles each) and the first entry whose IP, port, payload type
  and, if enabled, SSRC match wins, so software links entries in table order
  and gets the model's first-match rule. `ExAes67.RTL.Program.rx/2` produces
  the writes. Entries can be rewritten while traffic runs only if the chain
  being walked is not touched.

  Stats per entry (`stat_lane`): 0 packets, 1 lost, 2 reordered, 3 samples,
  with the model's definitions (sequence gap, behind the expected sequence).

  ## Differences from the model

  * Packets with CSRC, header extension or padding are counted in
    `st_bad_rtp` (the model decodes them; AES67 streams do not use them).
  * Packets longer than `bank_words * 8` bytes (2048 by default) are counted
    as `st_bad_length`; their beats are not stored.
  * The model's `bad_length` is a payload that is not a whole number of
    frames; here also a table entry with zero channels.

  ## Throughput

  Receive accepts one beat per cycle unless both banks are full (`tready`
  low; put a FIFO in front for bursts, the classifier does). Draining a
  packet takes about 22 cycles (hash 4, 2 per further chain entry, divider
  11, stats 3, window load 3) plus one cycle per sample; into the jitter
  buffer, which takes a write every second cycle, two per sample. At
  156.25 MHz a sample period is 3255 cycles: 1024 channels in 1 ms packets
  need about `2048 + 22 * packets` of them (77% as single channel streams,
  65% as 8 channel streams). Many very short packets do not fit: 1024 single
  channel streams at 125 us would need 5800 cycles.
  """
  use ExHdl.RTL
  import Bitwise, only: [bsl: 2]
  import ExHdl.RTL.Builder, only: [ceil_log2: 1]
  alias ExAes67.RTL.Interfaces

  @idle 0
  @h_rd 1
  @h_wait 2
  @e_rd 3
  @e_cmp 4
  @div 5
  @chk 6
  @st_rd 7
  @st_upd 8
  @l0 9
  @l1 10
  @l2 11
  @drain 12

  @stats ~w(ok bad_rtp no_stream bad_length)a
  def stats, do: @stats

  @doc "Options: `:streams` (512), `:hash_bits` (10), `:bank_words` (256, 64 bit words per packet bank)."
  def build(opts \\ []) do
    streams = Keyword.get(opts, :streams, 512)
    hb = Keyword.get(opts, :hash_bits, 10)
    bank_words = Keyword.get(opts, :bank_words, 256)
    idx_w = max(ceil_log2(streams), 1)
    baw = ceil_log2(bank_words)
    max_len = bank_words * 8
    name = "aes67_depack_#{streams}_#{hb}_#{bank_words}"

    module name do
      s = slave(:s_axis, Interfaces.udp_rx())
      cfg_we = input(:cfg_we, 1)
      cfg_sel = input(:cfg_sel, 2)
      cfg_addr = input(:cfg_addr, 16)
      cfg_data = input(:cfg_data, 32)
      stat_addr = input(:stat_addr, idx_w)
      stat_lane = input(:stat_lane, 3)
      stat_data = output(:stat_data, 32)
      wr_valid = output(:wr_valid, 1)
      wr_ready = input(:wr_ready, 1)
      wr_ch = output(:wr_ch, 11)
      wr_ts = output(:wr_ts, 32)
      wr_data = output(:wr_data, s(24))
      st = for k <- @stats, into: %{}, do: {k, output(:"st_#{k}", 32, reset: 0)}

      # -- memories ------------------------------------------------------------------
      pkt = memory(:pkt, width: 64, depth: 2 * bank_words)
      tab = memory(:streamtab, width: 128, depth: streams, byte: 32)
      hash = memory(:hash, width: idx_w + 1, depth: bsl(1, hb))
      stat = memory(:stat, width: 160, depth: streams, byte: 32)

      sel0 = wire(:sel0, cfg_we and cfg_sel == 0)
      lane = slice(cfg_addr, 0, 2)
      be = mux(lane, [const(1, 4), const(2, 4), const(4, 4), const(8, 4)])
      write_port(tab, addr: slice(cfg_addr, 2, idx_w), data: rep(cfg_data, 4), en: sel0, be: be)

      write_port(hash,
        addr: trunc(cfg_addr, hb),
        data: trunc(cfg_data, idx_w + 1),
        en: cfg_we and cfg_sel == 1
      )

      # -- receive side --------------------------------------------------------------
      wbank = reg(:wbank, 1)
      widx = reg(:widx, baw + 1)
      full = for b <- 0..1, do: reg(:"full#{b}", 1)
      sel = fn list -> mux(wbank, list) end

      s.tready <~ not sel.(full)
      take = wire(:take, s.tvalid and s.tready)
      first = wire(:first, widx == 0)
      tu = s.tuser

      write_port(pkt,
        addr: cat([wbank, trunc(widx, baw)]),
        data: s.tdata,
        en: take and widx < bank_words
      )

      d_ip = for b <- 0..1, do: reg(:"d_ip#{b}", 32, reset: nil)
      d_port = for b <- 0..1, do: reg(:"d_port#{b}", 16, reset: nil)
      d_len = for b <- 0..1, do: reg(:"d_len#{b}", 16, reset: nil)
      d_pt = for b <- 0..1, do: reg(:"d_pt#{b}", 7, reset: nil)
      d_seq = for b <- 0..1, do: reg(:"d_seq#{b}", 16, reset: nil)
      d_ts = for b <- 0..1, do: reg(:"d_ts#{b}", 32, reset: nil)
      d_ssrc = for b <- 0..1, do: reg(:"d_ssrc#{b}", 32, reset: nil)
      d_ok = for b <- 0..1, do: reg(:"d_ok#{b}", 1, reset: nil)

      sync do
        if take do
          if s.tlast do
            widx <~ 0
            wbank <~ not wbank
          else
            if widx < bank_words, do: widx <~ add_wrap(widx, 1)
          end
        end

        for b <- 0..1 do
          if take and wbank == b do
            if first do
              Enum.at(d_ip, b) <~ slice(tu, 0, 32)
              Enum.at(d_port, b) <~ slice(tu, 32, 16)
              Enum.at(d_len, b) <~ slice(tu, 80, 16)
              Enum.at(d_pt, b) <~ slice(s.tdata, 8, 7)
              Enum.at(d_seq, b) <~ cat([slice(s.tdata, 16, 8), slice(s.tdata, 24, 8)])
              Enum.at(d_ts, b) <~ bswap(slice(s.tdata, 32, 32))
              Enum.at(d_ok, b) <~ (slice(s.tdata, 0, 8) == 0x80 and slice(tu, 80, 16) >= 12)
            end

            if widx == 1, do: Enum.at(d_ssrc, b) <~ bswap(slice(s.tdata, 0, 32))
            if s.tlast, do: Enum.at(full, b) <~ 1
          end
        end
      end

      # -- drain side ----------------------------------------------------------------
      pst = reg(:pst, 4)
      rbank = reg(:rbank, 1)
      rsel = fn list -> mux(rbank, list) end
      is = fn code -> pst == code end
      p_ip = wire(:p_ip, rsel.(d_ip))
      p_port = wire(:p_port, rsel.(d_port))
      p_len = wire(:p_len, rsel.(d_len))
      p_pt = wire(:p_pt, rsel.(d_pt))
      p_seq = wire(:p_seq, rsel.(d_seq))
      p_ts = wire(:p_ts, rsel.(d_ts))
      p_ssrc = wire(:p_ssrc, rsel.(d_ssrc))

      h_rd = read_port(hash, addr: bucket(p_ip, p_port, hb), en: is.(@h_rd), name: :h_rd)
      cur = reg(:cur, idx_w)
      e_rd = read_port(tab, addr: cur, en: is.(@e_rd), name: :e_rd)
      l3 = slice(e_rd, 96, 32)
      e_port = slice(e_rd, 32, 16)
      e_pt = slice(e_rd, 48, 7)
      e_sen = slice(e_rd, 55, 1)
      e_fmt = slice(e_rd, 56, 1)
      e_ch = slice(l3, 0, 8)
      e_base = slice(l3, 8, 10)
      e_next = slice(l3, 18, idx_w)
      e_nv = slice(l3, 18 + idx_w, 1)

      match =
        wire(
          :match,
          slice(e_rd, 0, 32) == p_ip and e_port == p_port and e_pt == p_pt and
            (e_sen == 0 or slice(e_rd, 64, 32) == p_ssrc)
        )

      m_ch = reg(:m_ch, 8, reset: nil)
      m_base = reg(:m_base, 10, reset: nil)
      m_fmt = reg(:m_fmt, 1, reset: nil)
      m_idx = reg(:m_idx, idx_w, reset: nil)

      # restoring divider: payload bytes / bytes per frame
      dnd = reg(:dnd, 11, reset: nil)
      rem_ = reg(:rem, 11, reset: nil)
      quo = reg(:quo, 11, reset: nil)
      cnt = reg(:cnt, 4, reset: nil)

      fb =
        wire(:fb, mux(m_fmt, cat([m_ch, const(0, 1)]), zext(m_ch, 10) + cat([m_ch, const(0, 1)])))

      rem2 = wire(:rem2, cat([trunc(rem_, 10), slice(dnd, 10, 1)]))
      ge = wire(:ge, rem2 >= fb)
      over = wire(:over, p_len > max_len)

      # stats read-modify-write
      s_rd = read_port(stat, addr: m_idx, en: is.(@st_rd), name: :s_rd)
      exp_v = slice(s_rd, 144, 1)
      exp_s = slice(s_rd, 128, 16)
      gap = wire(:gap, as_signed(sub_wrap(p_seq, exp_s)))
      lost_add = wire(:lost_add, mux(exp_v == 1 and gap > 0, as_unsigned(gap), const(0, 16)))
      reord = wire(:reord, exp_v == 1 and gap < 0)
      nsamp = wire(:nsamp, zext(quo * m_ch, 32))

      new_stat =
        cat([
          const(0, 15),
          const(1, 1),
          mux(reord, exp_s, add_wrap(p_seq, 1)),
          add_wrap(slice(s_rd, 96, 32), nsamp),
          add_wrap(slice(s_rd, 64, 32), zext(reord, 32)),
          add_wrap(slice(s_rd, 32, 32), zext(lost_add, 32)),
          add_wrap(slice(s_rd, 0, 32), 1)
        ])

      write_port(stat, addr: m_idx, data: new_stat, en: is.(@st_upd))
      sr = read_port(stat, addr: stat_addr, name: :sr)
      lane_r = reg(:lane_r, 3, reset: nil)

      stat_data
      <~ mux(lane_r, [
        slice(sr, 0, 32),
        slice(sr, 32, 32),
        slice(sr, 64, 32),
        slice(sr, 96, 32),
        slice(sr, 128, 32)
      ])

      # sample extraction window
      lo = reg(:lo, 64, reset: nil)
      hi = reg(:hi, 64, reset: nil)
      hi_ok = reg(:hi_ok, 1)
      fill = reg(:fill, 1)
      off = reg(:off, 3)
      rptr = reg(:rptr, baw)
      fleft = reg(:fleft, 11, reset: nil)
      cc = reg(:cc, 8, reset: nil)
      cur_ts = reg(:cur_ts, 32, reset: nil)
      o_valid = reg(:o_valid, 1)
      o_ch = reg(:o_ch, 11, reset: nil)
      o_ts = reg(:o_ts, 32, reset: nil)
      o_data = reg(:o_data, 24, reset: nil)

      bps = wire(:bps, mux(m_fmt, const(2, 3), const(3, 3)))
      noff = wire(:noff, zext(off, 4) + zext(bps, 4))
      avail = wire(:avail, noff < 8 or hi_ok == 1)
      can = wire(:can, is.(@drain) and avail and (not o_valid or wr_ready))
      shift = wire(:shift, can and noff >= 8)
      win = wire(:win, cat([hi, lo]))

      byte = fn o, k -> slice(win, (o + k) * 8, 8) end

      sample =
        wire(
          :sample,
          mux(
            off,
            for o <- 0..7 do
              mux(
                m_fmt,
                cat([byte.(o, 0), byte.(o, 1), const(0, 8)]),
                cat([byte.(o, 0), byte.(o, 1), byte.(o, 2)])
              )
            end
          )
        )

      rd_en = wire(:rd_en, is.(@l0) or is.(@l1) or shift)
      ridx = wire(:ridx, mux(is.(@l0), const(1, baw), mux(is.(@l1), const(2, baw), rptr)))
      p_rd = read_port(pkt, addr: cat([rbank, ridx]), en: rd_en, name: :p_rd)

      wr_valid <~ o_valid
      wr_ch <~ o_ch
      wr_ts <~ o_ts
      wr_data <~ as_signed(o_data)

      release = fn ->
        for b <- 0..1, do: if(rbank == b, do: Enum.at(full, b) <~ 0)
        rbank <~ not rbank
        pst <~ @idle
      end

      sync do
        lane_r <~ stat_lane
        if fill == 1, do: hi <~ p_rd
        fill <~ shift
        if fill == 1, do: hi_ok <~ 1
        if o_valid and wr_ready, do: o_valid <~ 0

        switch pst do
          @idle ->
            if rsel.(full) == 1 do
              if rsel.(d_ok) == 0 do
                st.bad_rtp <~ add_wrap(st.bad_rtp, 1)
                release.()
              else
                pst <~ @h_rd
              end
            end

          @h_rd ->
            pst <~ @h_wait

          @h_wait ->
            if slice(h_rd, idx_w, 1) == 1 do
              cur <~ slice(h_rd, 0, idx_w)
              pst <~ @e_rd
            else
              st.no_stream <~ add_wrap(st.no_stream, 1)
              release.()
            end

          @e_rd ->
            pst <~ @e_cmp

          @e_cmp ->
            if match do
              m_ch <~ e_ch
              m_base <~ e_base
              m_fmt <~ e_fmt
              m_idx <~ cur
              dnd <~ trunc(sub_wrap(p_len, 12), 11)
              rem_ <~ 0
              quo <~ 0
              cnt <~ 0
              pst <~ @div
            else
              if e_nv == 1 do
                cur <~ e_next
                pst <~ @e_rd
              else
                st.no_stream <~ add_wrap(st.no_stream, 1)
                release.()
              end
            end

          @div ->
            dnd <~ cat([trunc(dnd, 10), const(0, 1)])
            rem_ <~ mux(ge, sub_wrap(rem2, fb), rem2)
            quo <~ cat([trunc(quo, 10), ge])
            cnt <~ add_wrap(cnt, 1)
            if cnt == 10, do: pst <~ @chk

          @chk ->
            if rem_ != 0 or m_ch == 0 or over do
              st.bad_length <~ add_wrap(st.bad_length, 1)
              release.()
            else
              pst <~ @st_rd
            end

          @st_rd ->
            pst <~ @st_upd

          @st_upd ->
            st.ok <~ add_wrap(st.ok, 1)

            if quo == 0 do
              release.()
            else
              pst <~ @l0
            end

          @l0 ->
            pst <~ @l1

          @l1 ->
            lo <~ p_rd
            pst <~ @l2

          @l2 ->
            hi <~ p_rd
            hi_ok <~ 1
            rptr <~ 3
            off <~ 4
            fleft <~ quo
            cc <~ 0
            cur_ts <~ p_ts
            pst <~ @drain

          @drain ->
            if can do
              o_valid <~ 1
              o_ch <~ add_wrap(zext(m_base, 11), zext(cc, 11))
              o_ts <~ cur_ts
              o_data <~ sample
              off <~ trunc(noff, 3)

              if shift do
                lo <~ hi
                hi_ok <~ 0
                rptr <~ add_wrap(rptr, 1)
              end

              if cc == sub_wrap(m_ch, 1) do
                cc <~ 0
                cur_ts <~ add_wrap(cur_ts, 1)
                fleft <~ sub_wrap(fleft, 1)
                if fleft == 1, do: release.()
              else
                cc <~ add_wrap(cc, 1)
              end
            end

          _ ->
            pst <~ @idle
        end
      end
    end
  end

  defp bswap(x) do
    n = div(ExHdl.RTL.Expr.width(x), 8)
    ExHdl.RTL.Expr.cat(for i <- 0..(n - 1), do: ExHdl.RTL.Expr.slice(x, i * 8, 8))
  end

  # XOR fold of ip[31:16] ^ ip[15:0] ^ port into hb bits; same as Program.hash/3
  defp bucket(ip, port, hb) do
    x = rtl(do: bxor(bxor(slice(ip, 16, 16), slice(ip, 0, 16)), port))

    for i <- Enum.take_every(0..15, hb), reduce: nil do
      acc ->
        part = rtl(do: zext(slice(x, i, min(hb, 16 - i)), hb))
        Kernel.if(acc, do: rtl(do: bxor(acc, part)), else: part)
    end
  end
end
