defmodule ExAes67.RTL.JitterBuffer do
  @moduledoc """
  Timestamp-addressed jitter buffer synthesizing ExAes67.Model.JitterBuffer.
  Expressed as an idiomatic functional state transformation.

  A dual-port RAM stores `channels * depth` audio samples. A write from
  the network computes its slot address from `wr_ts` and `wr_ch`, reads
  the existing slot on port A, and one cycle later either commits the
  write or drops it, updating the diagnostic counters. Playout scans
  channels `0..channels-1` on each `tick`, reading slots sequentially on
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
  use ExHdl.Stateful
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

    stateful name do
      ports do
        input :wr_valid, 1
        output :wr_ready, 1
        input :wr_ch, 11
        input :wr_ts, 32
        input :wr_data, s(24)
        input :latency, sl.idx_w
        input :tick, 1
        input :rtp_ts, 32
        output :out_valid, 1
        output :out_ch, 10
        output :out_data, s(24)
        output :out_first, 1
        output :out_last, 1

        for k <- @stats do
          output :"st_#{k}", 32
        end
      end

      state do
        # Write stage
        reg :w_busy, 1, reset: 0
        reg :w_ch, 11, reset: 0
        reg :w_ts, 32, reset: 0
        reg :w_data, 24, reset: 0

        # Playout scan stage
        reg :scan, 1, reset: 0
        reg :ptr, 11, reset: 0
        reg :play_ts, 32, reset: 0
        reg :s1_valid, 1, reset: 0
        reg :s1_ch, 11, reset: 0

        # Registered outputs
        reg :out_valid, 1, reset: 0
        reg :out_ch, 10, reset: 0
        reg :out_data, s(24), reset: 0
        reg :out_first, 1, reset: 0
        reg :out_last, 1, reset: 0

        for k <- @stats do
          reg :"st_#{k}", 32, reset: 0
        end
      end

      step(fn inputs, state ->
        # Dual-port memory
        mem = memory(:slots, width: sl.width, depth: sl.words, style: style, byte: sl.lane_w)

        # 1. Playout Pipeline Stage Control
        tick_go = inputs.tick and not state.scan
        t_now = sub_wrap(inputs.rtp_ts, zext(inputs.latency, 32))

        # 2. Write Ingestion & Candidate Read (Port A)
        accept = inputs.wr_valid and not state.w_busy

        a_addr =
          wire(
            :a_addr,
            mux(
              state.w_busy,
              Slots.addr(sl, state.w_ts, state.w_ch),
              Slots.addr(sl, inputs.wr_ts, inputs.wr_ch)
            )
          )

        a_rd = read_port(mem, addr: a_addr, en: accept, name: :a_rd)
        {sv, stag, _} = Slots.fields(sl, Slots.pick(sl, a_rd, state.w_ch))

        # 3. Write Validation
        playing = state.scan or tick_go
        played = not playing or state.w_ch < state.ptr
        floor = add_wrap(mux(state.scan, state.play_ts, t_now), zext(played, 32))
        d = as_signed(sub_wrap(state.w_ts, floor))

        bad = state.w_ch >= n
        late = d < 0
        over = d >= depth
        dup = sv == 1 and stag == trunc(state.w_ts, tag)
        ok = state.w_busy and not bad and not late and not over and not dup

        # Commit Write to Memory Port A
        {word, be} = Slots.write(sl, Slots.encode(sl, state.w_ts, state.w_data), state.w_ch)
        write_port(mem, addr: a_addr, data: word, en: ok, be: be)

        # 4. Playout Scan & Collision Avoidance (Port B)
        b_addr = wire(:b_addr, Slots.addr(sl, state.play_ts, state.ptr))
        coll = wire(:coll, ok and a_addr == b_addr)
        issue = wire(:issue, state.scan and not coll)
        b_rd = read_port(mem, addr: b_addr, en: issue, name: :b_rd)

        {bv, btag, bdata} = Slots.fields(sl, Slots.pick(sl, b_rd, state.s1_ch))
        hit = wire(:hit, bv == 1 and btag == trunc(state.play_ts, tag))

        # 5. Pure Next State Computation (Registers)
        next_w_busy = accept
        next_w_ch = mux(accept, inputs.wr_ch, state.w_ch)
        next_w_ts = mux(accept, inputs.wr_ts, state.w_ts)
        next_w_data = mux(accept, as_unsigned(inputs.wr_data), state.w_data)

        next_scan = mux(tick_go, 1, mux(issue and state.ptr == n - 1, 0, state.scan))
        next_play_ts = mux(tick_go, t_now, state.play_ts)
        next_ptr = mux(issue, mux(state.ptr == n - 1, 0, add_wrap(state.ptr, 1)), state.ptr)
        next_s1_valid = issue
        next_s1_ch = mux(issue, state.ptr, state.s1_ch)

        next_out_valid = state.s1_valid
        next_out_ch = trunc(state.s1_ch, 10)
        next_out_first = state.s1_valid and state.s1_ch == 0
        next_out_last = state.s1_valid and state.s1_ch == n - 1
        next_out_data = as_signed(mux(hit and state.s1_valid, bdata, 0))

        events = [
          bad_channel: state.w_busy and bad,
          late: state.w_busy and not bad and late,
          overrun: state.w_busy and not bad and not late and over,
          duplicate: state.w_busy and not bad and not late and not over and dup,
          written: ok,
          tick_overrun: inputs.tick and state.scan,
          underrun: state.s1_valid and not hit,
          played: state.s1_valid and state.s1_ch == n - 1
        ]

        next_stats =
          for {k, trigger} <- events, into: %{} do
            cur = Map.fetch!(state, :"st_#{k}")
            {:"st_#{k}", mux(trigger, add_wrap(cur, 1), cur)}
          end

        # 6. Outputs and Next State
        outputs = %{
          wr_ready: not state.w_busy
        }

        next_state =
          %{
            w_busy: next_w_busy,
            w_ch: next_w_ch,
            w_ts: next_w_ts,
            w_data: next_w_data,
            scan: next_scan,
            ptr: next_ptr,
            play_ts: next_play_ts,
            s1_valid: next_s1_valid,
            s1_ch: next_s1_ch,
            out_valid: next_out_valid,
            out_ch: next_out_ch,
            out_first: next_out_first,
            out_last: next_out_last,
            out_data: next_out_data
          }
          |> Map.merge(next_stats)

        {outputs, next_state}
      end)
    end
  end
end
