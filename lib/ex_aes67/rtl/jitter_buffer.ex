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
      io = declare_ports(sl)
      mem = memory(:slots, width: sl.width, depth: sl.words, style: style, byte: sl.lane_w)

      # Write stage: Port A read-modify-write
      w = declare_write_stage(sl, mem, io)

      # Playout stage: Port B channel scan
      scan = declare_playout_stage(io)

      # Write validation & collision avoidance
      wr_eval = eval_write(n, depth, tag, w, scan)
      {word, be} = Slots.write(sl, Slots.encode(sl, w.ts, w.data), w.ch)
      write_port(mem, addr: w.addr, data: word, en: wr_eval.ok, be: be)

      b_addr = wire(:b_addr, Slots.addr(sl, scan.play_ts, scan.ptr))
      coll = wire(:coll, wr_eval.ok and w.addr == b_addr)
      issue = wire(:issue, scan.scan and not coll)
      b_rd = read_port(mem, addr: b_addr, en: issue, name: :b_rd)

      {bv, btag, bdata} = Slots.fields(sl, Slots.pick(sl, b_rd, scan.s1_ch))
      hit = wire(:hit, bv == 1 and btag == trunc(scan.play_ts, tag))

      sync do
        step_write_stage(w, io)
        step_playout_stage(scan, issue, n)
        drive_outputs(io, scan, hit, bdata, n)
        update_statistics(io.st, w, wr_eval, scan, io.tick, hit, n)
      end
    end
  end

  defp declare_ports(sl) do
    %{
      wr_valid: input(:wr_valid, 1),
      wr_ready: output(:wr_ready, 1),
      wr_ch: input(:wr_ch, 11),
      wr_ts: input(:wr_ts, 32),
      wr_data: input(:wr_data, s(24)),
      latency: input(:latency, sl.idx_w),
      tick: input(:tick, 1),
      rtp_ts: input(:rtp_ts, 32),
      out_valid: output(:out_valid, 1, reset: 0),
      out_ch: output(:out_ch, 10, reset: 0),
      out_data: output(:out_data, s(24), reset: 0),
      out_first: output(:out_first, 1, reset: 0),
      out_last: output(:out_last, 1, reset: 0),
      st: for(k <- @stats, into: %{}, do: {k, output(:"st_#{k}", 32, reset: 0)})
    }
  end

  defp declare_write_stage(sl, mem, io) do
    rtl do
      w_busy = reg(:w_busy, 1)
      w_ch = reg(:w_ch, 11)
      w_ts = reg(:w_ts, 32)
      w_data = reg(:w_data, 24)

      io.wr_ready <~ not w_busy
      accept = wire(:accept, io.wr_valid and not w_busy)

      a_addr =
        wire(:a_addr, mux(w_busy, Slots.addr(sl, w_ts, w_ch), Slots.addr(sl, io.wr_ts, io.wr_ch)))

      a_rd = read_port(mem, addr: a_addr, en: accept, name: :a_rd)
      {sv, stag, _} = Slots.fields(sl, Slots.pick(sl, a_rd, w_ch))

      %{
        busy: w_busy,
        ch: w_ch,
        ts: w_ts,
        data: w_data,
        accept: accept,
        addr: a_addr,
        sv: sv,
        stag: stag
      }
    end
  end

  defp declare_playout_stage(io) do
    rtl do
      scan = reg(:scan, 1)
      ptr = reg(:ptr, 11)
      play_ts = reg(:play_ts, 32)
      s1_valid = reg(:s1_valid, 1)
      s1_ch = reg(:s1_ch, 11)

      tick_go = wire(:tick_go, io.tick and not scan)
      t_now = wire(:t_now, sub_wrap(io.rtp_ts, zext(io.latency, 32)))

      %{
        scan: scan,
        ptr: ptr,
        play_ts: play_ts,
        s1_valid: s1_valid,
        s1_ch: s1_ch,
        tick_go: tick_go,
        t_now: t_now
      }
    end
  end

  defp eval_write(n, depth, tag, w, scan) do
    rtl do
      playing = wire(:playing, scan.scan or scan.tick_go)
      played = wire(:played, not playing or w.ch < scan.ptr)
      floor = wire(:floor, add_wrap(mux(scan.scan, scan.play_ts, scan.t_now), zext(played, 32)))
      d = wire(:d, as_signed(sub_wrap(w.ts, floor)))

      bad = wire(:bad, w.ch >= n)
      late = wire(:late, d < 0)
      over = wire(:over, d >= depth)
      dup = wire(:dup, w.sv == 1 and w.stag == trunc(w.ts, tag))
      ok = wire(:ok, w.busy and not bad and not late and not over and not dup)

      %{bad: bad, late: late, over: over, dup: dup, ok: ok}
    end
  end

  defp step_write_stage(w, io) do
    rtl do
      w.busy <~ w.accept

      if w.accept do
        w.ch <~ io.wr_ch
        w.ts <~ io.wr_ts
        w.data <~ as_unsigned(io.wr_data)
      end
    end
  end

  defp step_playout_stage(scan, issue, n) do
    rtl do
      if scan.tick_go do
        scan.scan <~ 1
        scan.play_ts <~ scan.t_now
      end

      scan.s1_valid <~ issue

      if issue do
        scan.s1_ch <~ scan.ptr

        if scan.ptr == n - 1 do
          scan.scan <~ 0
          scan.ptr <~ 0
        else
          scan.ptr <~ add_wrap(scan.ptr, 1)
        end
      end
    end
  end

  defp drive_outputs(io, scan, hit, bdata, n) do
    rtl do
      io.out_valid <~ scan.s1_valid
      io.out_ch <~ trunc(scan.s1_ch, 10)
      io.out_first <~ (scan.s1_valid and scan.s1_ch == 0)
      io.out_last <~ (scan.s1_valid and scan.s1_ch == n - 1)
      io.out_data <~ as_signed(mux(hit and scan.s1_valid, bdata, 0))
    end
  end

  defp update_statistics(st, w, wr_eval, scan, tick, hit, n) do
    rtl do
      events = [
        bad_channel: w.busy and wr_eval.bad,
        late: w.busy and not wr_eval.bad and wr_eval.late,
        overrun: w.busy and not wr_eval.bad and not wr_eval.late and wr_eval.over,
        duplicate:
          w.busy and not wr_eval.bad and not wr_eval.late and not wr_eval.over and wr_eval.dup,
        written: wr_eval.ok,
        tick_overrun: tick and scan.scan,
        underrun: scan.s1_valid and not hit,
        played: scan.s1_valid and scan.s1_ch == n - 1
      ]

      for {k, trigger} <- events do
        if trigger, do: st[k] <~ add_wrap(st[k], 1)
      end
    end
  end
end
