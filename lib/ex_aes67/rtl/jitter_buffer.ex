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
        # Write stage registers
        reg :w_busy, 1, reset: 0
        reg :w_ch, 11, reset: 0
        reg :w_ts, 32, reset: 0
        reg :w_data, 24, reset: 0

        # Playout scan stage registers
        reg :scan, 1, reset: 0
        reg :ptr, 11, reset: 0
        reg :play_ts, 32, reset: 0
        reg :s1_valid, 1, reset: 0
        reg :s1_ch, 11, reset: 0

        # Registered output registers
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
        mem = memory(:slots, width: sl.width, depth: sl.words, style: style, byte: sl.lane_w)

        # 1. Playout scan control (timing & address)
        scan_ctrl = eval_scan_control(inputs, state, sl)

        # 2. Write stage evaluation & collision check (Port A)
        {write_out, next_write, write_events, coll} =
          eval_write(inputs, state, mem, sl, tag, depth, n, scan_ctrl)

        wire(:coll, coll)

        # 3. Playout pipeline evaluation (Port B)
        {playout_out, next_playout, playout_events} =
          eval_playout(inputs, state, mem, sl, tag, n, scan_ctrl, coll)

        # 4. Diagnostic metrics update
        next_stats =
          update_metrics(state, write_events ++ playout_events)

        outputs = Map.merge(playout_out, write_out)
        next_state = Map.merge(next_write, next_playout) |> Map.merge(next_stats)

        {outputs, next_state}
      end)
    end
  end

  # =========================================================================
  # Playout Pipeline Sub-functions (Port B)
  # =========================================================================

  defp eval_scan_control(inputs, state, sl) do
    %{
      tick_go: inputs.tick and not state.scan,
      t_now: sub_wrap(inputs.rtp_ts, zext(inputs.latency, 32)),
      b_addr: Slots.addr(sl, state.play_ts, state.ptr)
    }
  end

  defp eval_playout(inputs, state, mem, sl, tag, n, scan_ctrl, coll) do
    issue = state.scan and not coll
    b_rd = read_port(mem, addr: scan_ctrl.b_addr, en: issue, name: :b_rd)

    {bv, btag, bdata} = Slots.fields(sl, Slots.pick(sl, b_rd, state.s1_ch))
    hit = bv == 1 and btag == trunc(state.play_ts, tag)
    is_last = state.ptr == n - 1
    s1_is_last = state.s1_ch == n - 1

    out_data =
      match_cond([
        {hit and state.s1_valid, bdata},
        {:default, 0}
      ])

    outputs = %{
      out_valid: state.s1_valid,
      out_ch: trunc(state.s1_ch, 10),
      out_first: state.s1_valid and state.s1_ch == 0,
      out_last: state.s1_valid and s1_is_last,
      out_data: as_signed(out_data)
    }

    scan_state =
      match_cond([
        {scan_ctrl.tick_go, %{scan: 1, play_ts: scan_ctrl.t_now, ptr: state.ptr}},
        {issue and is_last, %{scan: 0, play_ts: state.play_ts, ptr: 0}},
        {issue, %{scan: state.scan, play_ts: state.play_ts, ptr: add_wrap(state.ptr, 1)}},
        {:default, %{scan: state.scan, play_ts: state.play_ts, ptr: state.ptr}}
      ])

    next_state =
      scan_state
      |> Map.merge(%{
        s1_valid: issue,
        s1_ch: match_cond([{issue, state.ptr}, {:default, state.s1_ch}]),
        out_valid: outputs.out_valid,
        out_ch: outputs.out_ch,
        out_first: outputs.out_first,
        out_last: outputs.out_last,
        out_data: outputs.out_data
      })

    events = [
      tick_overrun: inputs.tick and state.scan,
      underrun: state.s1_valid and not hit,
      played: state.s1_valid and s1_is_last
    ]

    {outputs, next_state, events}
  end

  # =========================================================================
  # Write Pipeline Sub-functions (Port A)
  # =========================================================================

  defp eval_write(inputs, state, mem, sl, tag, depth, n, scan_ctrl) do
    accept = inputs.wr_valid and not state.w_busy

    a_addr =
      match_cond([
        {state.w_busy, Slots.addr(sl, state.w_ts, state.w_ch)},
        {:default, Slots.addr(sl, inputs.wr_ts, inputs.wr_ch)}
      ])

    a_rd = read_port(mem, addr: a_addr, en: accept, name: :a_rd)
    {sv, stag, _} = Slots.fields(sl, Slots.pick(sl, a_rd, state.w_ch))

    {ok, events} = validate_write(state, sv, stag, tag, depth, n, scan_ctrl)

    # Commit write to RAM Port A
    {word, be} = Slots.write(sl, Slots.encode(sl, state.w_ts, state.w_data), state.w_ch)
    write_port(mem, addr: a_addr, data: word, en: ok, be: be)

    coll = ok and a_addr == scan_ctrl.b_addr
    outputs = %{wr_ready: not state.w_busy}

    next_state =
      match_cond([
        {accept,
         %{
           w_busy: 1,
           w_ch: inputs.wr_ch,
           w_ts: inputs.wr_ts,
           w_data: as_unsigned(inputs.wr_data)
         }},
        {:default,
         %{
           w_busy: 0,
           w_ch: state.w_ch,
           w_ts: state.w_ts,
           w_data: state.w_data
         }}
      ])

    {outputs, next_state, events, coll}
  end

  defp validate_write(state, sv, stag, tag, depth, n, scan_ctrl) do
    playing = state.scan or scan_ctrl.tick_go
    played = not playing or state.w_ch < state.ptr

    floor =
      add_wrap(
        match_cond([{state.scan, state.play_ts}, {:default, scan_ctrl.t_now}]),
        zext(played, 32)
      )

    d = as_signed(sub_wrap(state.w_ts, floor))

    bad = state.w_ch >= n
    late = d < 0
    over = d >= depth
    dup = sv == 1 and stag == trunc(state.w_ts, tag)
    ok = state.w_busy and not bad and not late and not over and not dup

    events = [
      bad_channel: state.w_busy and bad,
      late: state.w_busy and not bad and late,
      overrun: state.w_busy and not bad and not late and over,
      duplicate: state.w_busy and not bad and not late and not over and dup,
      written: ok
    ]

    {ok, events}
  end

  # =========================================================================
  # Diagnostic Statistics Reducer
  # =========================================================================

  defp update_metrics(state, events) do
    for {k, trigger} <- events, into: %{} do
      cur = Map.fetch!(state, :"st_#{k}")

      next =
        match_cond([
          {trigger, add_wrap(cur, 1)},
          {:default, cur}
        ])

      {:"st_#{k}", next}
    end
  end
end
