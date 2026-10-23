defmodule ExAes67.RTL.JitterBuffer do
  @moduledoc """
  Timestamp addressed jitter buffer, the RTL of `ExAes67.Model.JitterBuffer`.

  ## Scheme

  One slot per `{channel, ts mod depth}` holding `{valid, tag, sample}` (see
  `ExAes67.RTL.Slots`), exactly the model's slots. A write is a
  read-modify-write on port A (duplicate check), the playout scan reads
  port B, so the two never wait for each other except for a one cycle stall
  when both address the same word. The tag makes playout need no clearing:
  a slot is played only if its tag equals the frame timestamp, everything
  else reads as silence and counts as underrun. With `tag_bits: 32`
  (default) behaviour is identical to the model including 32 bit
  timestamp wrap; smaller tags pack two slots per 72 bit word (half the
  memory) at the price of a stale slot replaying after `2^(tag_bits +
  log2 depth)` frames of silence on that channel.

  ## Ports (clock `clk`, reset `rst_n`)

  | Port | Dir | Meaning |
  |---|---|---|
  | `wr_valid`, `wr_ready`, `wr_ch` (11), `wr_ts` (32), `wr_data` (s24) | in/out | sample write, one per two cycles at most (rejected writes take two cycles too) |
  | `tick`, `rtp_ts` (32) | in | media clock: `tick` pulses once per sample period, `rtp_ts` is the media time of that period (stable until the next tick) |
  | `latency` | in | playout delay in frames, `< depth` |
  | `out_valid`, `out_ch`, `out_data` (s24), `out_first`, `out_last` | out | TDM playout: after a tick channels `0..channels-1` follow in order, one per cycle (a cycle is skipped on a write collision) |
  | `st_*` | out | 32 bit counters: `written late overrun duplicate bad_channel underrun played tick_overrun` |

  Semantics against the model: a tick plays frame `rtp_ts - latency`. The
  play instant of channel `c` is the cycle its slot is read, so a write for
  the frame being played is late for channels already read and fine for the
  others; with writes and scan not overlapping this is the model's
  `write` then `play`. A tick while a scan is running is ignored
  (`st_tick_overrun`); the scan takes `channels` cycles plus collisions, so the
  sample period must be longer. The media clock must be continuous: on a
  step of `rtp_ts` the tags make stale slots read as underruns, as in the model.

  Memory for 1024 channels x 64 frames: see `ExAes67.RTL.Slots` (8 URAM with
  `tag_bits: 11`, 16 with 32).
  """
  use ExHdl.RTL
  alias ExAes67.RTL.Slots

  @stats ~w(written late overrun duplicate bad_channel underrun played tick_overrun)a
  def stats, do: @stats

  @doc "Options: `:channels` (1024), `:depth` (64, power of two), `:tag_bits` (32), `:style` (`:block`)."
  def build(opts \\ []) do
    n = Keyword.get(opts, :channels, 1024)
    depth = Keyword.get(opts, :depth, 64)
    tag = Keyword.get(opts, :tag_bits, 32)
    style = Keyword.get(opts, :style, :block)
    sl = Slots.new(n, depth, tag)
    name = "aes67_jb_#{n}x#{depth}_t#{tag}_#{style}"

    module name do
      wr_valid = input(:wr_valid, 1)
      wr_ready = output(:wr_ready, 1)
      wr_ch = input(:wr_ch, 11)
      wr_ts = input(:wr_ts, 32)
      wr_data = input(:wr_data, s(24))
      %{tick: tick, rtp_ts: rtp_ts} = ExPtp.RTL.Ifc.media_clock(:slave)
      latency = input(:latency, sl.idx_w)

      out_valid = output(:out_valid, 1, reset: 0)
      out_ch = output(:out_ch, 10, reset: 0)
      out_data = output(:out_data, s(24), reset: 0)
      out_first = output(:out_first, 1, reset: 0)
      out_last = output(:out_last, 1, reset: 0)
      st = for k <- @stats, into: %{}, do: {k, output(:"st_#{k}", 32, reset: 0)}

      mem = memory(:slots, width: sl.width, depth: sl.words, style: style, byte: sl.lane_w)

      # write side: cycle 0 accepts and reads, cycle 1 checks and writes
      w_busy = reg(:w_busy, 1)
      w_ch = reg(:w_ch, 11)
      w_ts = reg(:w_ts, 32)
      w_data = reg(:w_data, 24)

      wr_ready <~ not w_busy
      accept = wire(:accept, wr_valid and not w_busy)

      a_addr =
        wire(:a_addr, mux(w_busy, Slots.addr(sl, w_ts, w_ch), Slots.addr(sl, wr_ts, wr_ch)))

      a_rd = read_port(mem, addr: a_addr, en: accept, name: :a_rd)
      {sv, stag, _} = Slots.fields(sl, Slots.pick(sl, a_rd, w_ch))

      # playout side
      scan = reg(:scan, 1)
      ptr = reg(:ptr, 11)
      play_ts = reg(:play_ts, 32)
      s1_valid = reg(:s1_valid, 1)
      s1_ch = reg(:s1_ch, 11)

      tick_go = wire(:tick_go, tick and not scan)
      t_now = wire(:t_now, sub_wrap(rtp_ts, zext(latency, 32)))
      playing = wire(:playing, scan or tick_go)
      played = wire(:played, not playing or w_ch < ptr)
      floor = wire(:floor, add_wrap(mux(scan, play_ts, t_now), zext(played, 32)))
      d = wire(:d, as_signed(sub_wrap(w_ts, floor)))

      bad = wire(:bad, w_ch >= n)
      late = wire(:late, d < 0)
      over = wire(:over, d >= depth)
      dup = wire(:dup, sv == 1 and stag == trunc(w_ts, tag))
      ok = wire(:ok, w_busy and not bad and not late and not over and not dup)
      {word, be} = Slots.write(sl, Slots.encode(sl, w_ts, w_data), w_ch)
      write_port(mem, addr: a_addr, data: word, en: ok, be: be)

      b_addr = wire(:b_addr, Slots.addr(sl, play_ts, ptr))
      coll = wire(:coll, ok and a_addr == b_addr)
      issue = wire(:issue, scan and not coll)
      b_rd = read_port(mem, addr: b_addr, en: issue, name: :b_rd)
      {bv, btag, bdata} = Slots.fields(sl, Slots.pick(sl, b_rd, s1_ch))
      hit = wire(:hit, bv == 1 and btag == trunc(play_ts, tag))

      sync do
        w_busy <~ accept

        if accept do
          w_ch <~ wr_ch
          w_ts <~ wr_ts
          w_data <~ as_unsigned(wr_data)
        end

        if w_busy do
          if bad do
            st.bad_channel <~ add_wrap(st.bad_channel, 1)
          else
            if late do
              st.late <~ add_wrap(st.late, 1)
            else
              if over do
                st.overrun <~ add_wrap(st.overrun, 1)
              else
                if dup,
                  do: st.duplicate <~ add_wrap(st.duplicate, 1),
                  else: st.written <~ add_wrap(st.written, 1)
              end
            end
          end
        end

        if tick and scan, do: st.tick_overrun <~ add_wrap(st.tick_overrun, 1)

        if tick_go do
          scan <~ 1
          play_ts <~ t_now
        end

        s1_valid <~ issue

        if issue do
          s1_ch <~ ptr

          if ptr == n - 1 do
            scan <~ 0
            ptr <~ 0
          else
            ptr <~ add_wrap(ptr, 1)
          end
        end

        out_valid <~ s1_valid
        out_ch <~ trunc(s1_ch, 10)
        out_first <~ (s1_valid and s1_ch == 0)
        out_last <~ (s1_valid and s1_ch == n - 1)
        out_data <~ as_signed(mux(hit and s1_valid, bdata, 0))

        if s1_valid do
          if not hit, do: st.underrun <~ add_wrap(st.underrun, 1)
          if s1_ch == n - 1, do: st.played <~ add_wrap(st.played, 1)
        end
      end
    end
  end
end
