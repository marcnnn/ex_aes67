defmodule ExAes67.Integration.RxChainTest do
  @moduledoc """
  Receive side end to end in RTL simulation: XGMII words -> ex_net MAC RX -> classifier -> UDP
  payload extractor -> ex_aes67 depacketiser -> jitter buffer (media clock from the ex_ptp
  `MediaNco`), and in parallel the same frames through the ex_ptp `RxStamp` with the
  `TimestampUnit` and the wallclock. Random AES67 streams, PTP event messages (L2 and UDP),
  other traffic, VLAN tags, IP options, bad FCS. The jitter buffer output frames and counters
  must equal the BEAM models, every frame must carry the model's PTP classification and the
  wallclock model's timestamp.
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias ExAes67.{RTP, RTP.Payload}
  alias ExAes67.Model.{Depacketiser, JitterBuffer}
  alias ExAes67.RTL.Program
  alias ExAes67.Test.Chains
  alias ExNet.{Ethernet, Filter, IPv4, UDP}
  alias ExNet.MAC.Tx64
  alias ExNet.RTL.Classifier
  alias ExPtp.{Message, Timestamp, Wallclock}
  alias ExPtp.RTL.{Meta, PtpDetect, TimestampUnit}
  alias ExAes67.Test.Loop

  @moduletag timeout: 1_200_000
  @tick 192
  @channels 4
  @depth 16
  @latency 3
  @ncls 4
  @sec 5000
  @mc_offset 0x1000
  @idle {0x0707070707070707, 0xFF}
  @src_mac <<2, 0, 0, 0, 0, 0x42>>
  @src_ip {10, 0, 0, 7}
  # events from the one in which the Start word is applied to the capture register (1 until `rx_sof`, 3 more in the unit)
  @capture 4

  # -- configuration ---------------------------------------------------------------------

  defp entries do
    [
      %{
        id: :a,
        dst_ip: {239, 69, 1, 1},
        dst_port: 5004,
        ssrc: nil,
        pt: 97,
        channels: 2,
        base_channel: 0,
        format: :l24
      },
      %{
        id: :b,
        dst_ip: {239, 69, 1, 2},
        dst_port: 5006,
        ssrc: 0xB,
        pt: 98,
        channels: 1,
        base_channel: 2,
        format: :l16
      },
      %{
        id: :c,
        dst_ip: {239, 69, 1, 3},
        dst_port: 5008,
        ssrc: nil,
        pt: 99,
        channels: 1,
        base_channel: 3,
        format: :l24
      }
    ]
  end

  defp filter do
    Enum.reduce(Enum.with_index(entries()), Filter.new(default: :host), fn {e, i}, f ->
      Filter.add(f, %{ip_dst: e.dst_ip, udp_dst_port: e.dst_port}, {:stream, i})
    end)
    |> Filter.add(%{udp_dst_port: 319..320}, :host)
  end

  defp inc, do: Chains.wc_inc(@tick)
  defp comp, do: (@capture * inc()) >>> 16

  # -- frame builders --------------------------------------------------------------------

  @tag_order [%{tpid: 0x88A8, pcp: 0, dei: 0, vid: 100}, %{tpid: 0x8100, pcp: 3, dei: 0, vid: 7}]

  defp tags(n), do: Enum.take(@tag_order, n)

  defp pad60(f) when byte_size(f) < 60, do: f <> :binary.copy(<<0>>, 60 - byte_size(f))
  defp pad60(f), do: f

  defp udp_frame(dst_ip, port, payload, ntags, ihl_extra) do
    udp = UDP.encode(%UDP{src_port: 4000, dst_port: port, payload: payload}, @src_ip, dst_ip)

    ip =
      IPv4.encode(%IPv4{
        src: @src_ip,
        dst: dst_ip,
        protocol: 17,
        ttl: 16,
        options: :binary.copy(<<1>>, 4 * ihl_extra),
        payload: udp
      })

    mac =
      if Ethernet.multicast_ip?(dst_ip),
        do: Ethernet.multicast_mac(dst_ip),
        else: <<2, 0, 0, 0, 0, 1>>

    pad60(
      Ethernet.encode(%Ethernet{
        dst: mac,
        src: @src_mac,
        tags: tags(ntags),
        ethertype: 0x0800,
        payload: ip
      })
    )
  end

  defp ptp_frame(type, kind, ntags, seq) do
    body = if type == :follow_up, do: :precise_origin_timestamp, else: :origin_timestamp
    msg = Message.new(type, {<<1, 2, 3, 4, 5, 6, 7, 8>>, 1}, seq, %{body => Timestamp.new(1, 2)})
    bin = Message.encode(msg)

    case kind do
      :udp ->
        port = if type in [:sync, :delay_req], do: 319, else: 320
        udp_frame({224, 0, 1, 129}, port, bin, ntags, 0)

      :l2 ->
        pad60(
          Ethernet.encode(%Ethernet{
            dst: <<1, 0x1B, 0x19, 0, 0, 0>>,
            src: @src_mac,
            tags: tags(ntags),
            ethertype: 0x88F7,
            payload: bin
          })
        )
    end
  end

  defp arp_frame do
    Ethernet.encode(%Ethernet{
      dst: Ethernet.broadcast(),
      src: @src_mac,
      ethertype: 0x0806,
      payload: :binary.copy(<<1>>, 46)
    })
  end

  # distinct nonzero samples (L16 left justified in 24 bits)
  defp sample(:l24, n), do: 1 + rem(n * 7919, 8_000_000) * if(rem(n, 3) == 0, do: -1, else: 1)
  defp sample(:l16, n), do: 1 + rem(n * 131, 30_000) * if(rem(n, 2) == 0, do: -1, else: 1)

  defp rtp_payload(e, seq, ts, nframes, salt) do
    frames =
      for f <- 0..(nframes - 1),
          do: for(c <- 0..(e.channels - 1), do: sample(e.format, salt + 17 * f + c))

    RTP.encode(%RTP{
      pt: e.pt,
      seq: seq &&& 0xFFFF,
      ts: ts &&& 0xFFFFFFFF,
      ssrc: e.ssrc || 0xAA,
      payload: Payload.pack(e.format, frames)
    })
  end

  # -- plan: per sample period, `{offset, descriptor}` -----------------------------------------

  defp plan(periods, seed) do
    :rand.seed(:exsss, {seed, 11, 13})

    for k <- 0..(periods - 1) do
      slots = [5, 30, 55, 80]

      for off <- slots, :rand.uniform(100) <= 80 do
        {off, desc(k)}
      end
    end
  end

  defp desc(_k) do
    case :rand.uniform(10) do
      n when n <= 5 ->
        {:rtp, Enum.random([:a, :a, :b, :c]), :rand.uniform(3), rand_extras()}

      n when n <= 7 ->
        {:ptp, Enum.random([:sync, :delay_req, :follow_up]), Enum.random([:udp, :l2]),
         :rand.uniform(3) - 1, bad?(8)}

      8 ->
        {:other, :arp}

      9 ->
        {:other, :udp}

      10 ->
        {:rtp, :a, 2, %{ntags: 0, ihl: 0, bad: false, wrong_pt: true}}
    end
  end

  defp bad?(pct), do: :rand.uniform(pct) == 1

  defp rand_extras,
    do: %{ntags: :rand.uniform(3) - 1, ihl: Enum.random([0, 0, 2]), bad: bad?(8), wrong_pt: false}

  # -- scenario driver ---------------------------------------------------------------------

  defp cfg_writes do
    {dp, index} = Program.rx(entries(), streams: 8, hash_bits: 3)
    {Classifier.program(filter(), @ncls, 4), dp, index}
  end

  defp frame_words(frame, lane4?) do
    [start | rest] = Tx64.run([frame])
    start = if lane4?, do: {0xD5_55_55_FB_07_07_07_07, 0x1F}, else: start
    [start | rest]
  end

  defp prepare(periods, seed) do
    plan = plan(periods, seed)
    {cls, dp, index} = cfg_writes()
    mod = Chains.rx_chain(tick_cycles: @tick, channels: @channels, depth: @depth, entries: @ncls)
    ncfg = max(length(cls), length(dp))
    align_at = 6 + ncfg + 4
    stat_reqs = for {_, i} <- Enum.sort(Map.to_list(index)), lane <- 0..3, do: {i, lane}

    init = %{
      plan: plan,
      periods_seen: 0,
      queue: [],
      cur: nil,
      seq: %{a: 0, b: 65_530, c: 100},
      salt: 0,
      sent: [],
      ticks: [],
      tail: nil,
      stats: [],
      last_sof: nil
    }

    n_events = align_at + 2 * @tick + periods * @tick + 8 * @tick + 100
    fun = fn st, ev -> step(st, ev, cls, dp, align_at, stat_reqs) end
    {mod, init, n_events, fun, align_at}
  end

  defp run(periods, seed) do
    {mod, init, n_events, fun, _} = prepare(periods, seed)
    Loop.run(mod, n_events, init, fun)
  end

  # Long scenario in Verilator only. The media clock free-runs from the wallclock, so its ticks are
  # found in a short idle run and then predicted (one every `@tick` events); the driver plans
  # all frames against that, the stimulus is replayed in Verilator and the real ticks must be
  # the predicted ones.
  defp run_verilator(periods, seed) do
    {mod, init, n_events, fun, align_at} = prepare(periods, seed)
    idle_n = align_at + 3 * @tick

    {:ok, cosim} = ExHdl.RTL.Cosim.build(mod)

    idle =
      Loop.run_cosim(mod, idle_n, init, fun, fn _ -> %{jb_tick: 0, rtp_ts: 0, stat_data: 0} end)

    {t0, r0} =
      for({e, i} <- Enum.with_index(idle.events), e.outs.jb_tick == 1, do: {i, e.outs.rtp_ts})
      |> hd()

    _ = cosim

    oracle = fn i ->
      tick = i >= t0 and rem(i - t0, @tick) == 0

      %{
        jb_tick: if(tick, do: 1, else: 0),
        rtp_ts: if(i >= t0, do: r0 + div(i - t0, @tick), else: 0),
        stat_data: 0
      }
    end

    res = Loop.run_cosim(mod, n_events, init, fun, oracle)

    for {e, i} <- Enum.with_index(res.events) do
      assert e.outs.jb_tick == oracle.(i).jb_tick, "tick prediction failed at event #{i}"
    end

    res
  end

  defp step(st, ev, cls, dp, align_at, stat_reqs) do
    i = ev.i
    o = ev.outs

    # one-cycle strobes
    ci = i - 6
    cw = Enum.at(cls, ci)
    dw = Enum.at(dp, ci)

    base = %{
      rst_n: if(i < 3, do: 0, else: 1),
      set_wr: if(i == 4, do: 1, else: 0),
      set_sec: @sec,
      set_ns: 0,
      rx_comp: comp(),
      mc_offset: @mc_offset,
      align: if(i == align_at, do: 1, else: 0),
      latency: @latency,
      cls_cfg_we: if(ci >= 0 and cw, do: 1, else: 0),
      cls_cfg_addr: if(ci >= 0 and cw, do: elem(cw, 0), else: 0),
      cls_cfg_data: if(ci >= 0 and cw, do: elem(cw, 1), else: 0),
      dp_cfg_we: if(ci >= 0 and dw, do: 1, else: 0),
      dp_cfg_sel: if(ci >= 0 and dw, do: dw.cfg_sel, else: 0),
      dp_cfg_addr: if(ci >= 0 and dw, do: dw.cfg_addr, else: 0),
      dp_cfg_data: if(ci >= 0 and dw, do: dw.cfg_data, else: 0),
      stamp_tready: 1
    }

    # a tick of the jitter buffer starts a period: its frames go out relative to it
    st =
      if o.jb_tick == 1 do
        k = length(st.ticks)
        st = %{st | ticks: [{i, o.rtp_ts} | st.ticks]}
        st = build_period(st, k, i, o.rtp_ts)
        st
      else
        st
      end

    # tail: read the per stream counters of the depacketiser
    {st, stat} = tail(st, i, stat_reqs, o)

    # the XGMII word of this event
    {word, st} = next_word(st, i)
    {w, c} = word

    {Map.merge(base, Map.merge(stat, %{xgmii_rxd: w, xgmii_rxc: c})), st}
  end

  defp tail(st, i, reqs, o) do
    last_tick = st.ticks |> List.first() |> then(&(&1 && elem(&1, 0)))
    nperiods = length(st.plan)
    done = length(st.ticks) > nperiods + 4

    cond do
      not done ->
        {st, %{dp_stat_addr: 0, dp_stat_lane: 0}}

      st.tail == nil ->
        {%{st | tail: {i, reqs}}, %{dp_stat_addr: 0, dp_stat_lane: 0}}

      true ->
        {_t0, rest} = st.tail
        _ = last_tick

        # the value requested in the previous event is on the output now
        st =
          case st.stats do
            [{:req, r} | more] -> %{st | stats: [{r, o.stat_data} | more]}
            other -> %{st | stats: other}
          end

        case rest do
          [{a, l} = r | more] ->
            {%{st | tail: {i, more}, stats: [{:req, r} | st.stats]},
             %{dp_stat_addr: a, dp_stat_lane: l}}

          [] ->
            {st, %{dp_stat_addr: 0, dp_stat_lane: 0}}
        end
    end
  end

  defp build_period(st, k, i, now) do
    descs = Enum.at(st.plan, k, [])

    Enum.reduce(descs, st, fn {off, d}, st ->
      {frame, info, st} = make(d, now, st)
      %{st | queue: st.queue ++ [{i + off, frame, info, k}]}
    end)
  end

  defp stream(id), do: Enum.find(entries(), &(&1.id == id))

  defp make({:rtp, id, nframes, ex}, now, st) do
    e = stream(id)
    seq = st.seq[id]
    # occasionally skip a sequence number (a lost packet)
    skip = if rem(st.salt, 7) == 3, do: 1, else: 0
    seq = seq + skip
    ts = now + 1
    pt_e = if ex.wrong_pt, do: %{e | pt: 5}, else: e
    payload = rtp_payload(pt_e, seq, ts, nframes, st.salt)
    frame = udp_frame(e.dst_ip, e.dst_port, payload, ex.ntags, ex.ihl)

    st = %{st | seq: Map.put(st.seq, id, seq + 1), salt: st.salt + 1}
    {frame, %{kind: :rtp, bad: ex.bad, udp: {e.dst_ip, e.dst_port, payload}}, st}
  end

  defp make({:ptp, type, kind, ntags, bad}, _now, st) do
    seq = st.salt
    frame = ptp_frame(type, kind, ntags, seq)
    {frame, %{kind: :ptp, bad: bad, type: type}, %{st | salt: st.salt + 1}}
  end

  defp make({:other, :arp}, _, st), do: {arp_frame(), %{kind: :other, bad: false}, st}

  defp make({:other, :udp}, _, st),
    do:
      {udp_frame({239, 69, 9, 9}, 7000, "something else entirely.....", 0, 0),
       %{kind: :other, bad: false}, st}

  # the next XGMII word: idle, or the next word of the frame in flight, or the start of a due frame
  defp next_word(%{cur: [w | rest]} = st, _i),
    do: {w, %{st | cur: if(rest == [], do: nil, else: rest)}}

  defp next_word(%{queue: [{due, frame, info, k} | more]} = st, i) when due <= i do
    lane4? = rem(i, 3) == 0
    [w | rest] = frame_words(frame, lane4?)
    # a bad FCS: flip a bit of source MAC byte 2 (frame byte 8, lane 0 of the second data word)
    {rest, frame} =
      if info.bad do
        {List.update_at(rest, 1, fn {d, c} -> {bxor(d, 0x40), c} end), flip8(frame)}
      else
        {rest, frame}
      end

    sent = {i, frame, info, k}
    {w, %{st | queue: more, cur: if(rest == [], do: nil, else: rest), sent: [sent | st.sent]}}
  end

  defp next_word(st, _), do: {@idle, st}

  defp flip8(<<a::binary-size(8), b, rest::binary>>),
    do: <<a::binary, bxor(b, 0x40), rest::binary>>

  # -- checks -----------------------------------------------------------------------------

  defp collect_jb(ev) do
    {frames, _} =
      Enum.reduce(ev, {[], []}, fn e, {done, cur} ->
        o = e.outs

        if o.out_valid == 1 do
          cur = [o.out_data | cur]
          if o.out_last == 1, do: {[Enum.reverse(cur) | done], []}, else: {done, cur}
        else
          {done, cur}
        end
      end)

    Enum.reverse(frames)
  end

  defp collect_stamp(ev) do
    {frames, _} =
      Enum.reduce(ev, {[], <<>>}, fn e, {done, cur} ->
        o = e.outs

        if o.stamp_tvalid == 1 do
          n = Enum.count(0..7, &((o.stamp_tkeep >>> &1 &&& 1) == 1))
          cur = cur <> binary_part(<<o.stamp_tdata::little-64>>, 0, n)
          if o.stamp_tlast == 1, do: {[{cur, o.stamp_tuser} | done], <<>>}, else: {done, cur}
        else
          {done, cur}
        end
      end)

    Enum.reverse(frames)
  end

  defp seed, do: String.to_integer(System.get_env("INTEG_SEED", "1"))

  defp scenario do
    s = seed()
    cached("rx_5_#{s}_c#{@capture}", fn -> run(5, s) end)
  end

  setup_all do
    %{res: scenario()}
  end

  test "XGMII to jitter buffer samples and PTP timestamps equal the models", %{res: res} do
    check(res, 5)
  end

  @tag :verilator
  test "long random scenario in Verilator: samples and timestamps equal the models" do
    periods = String.to_integer(System.get_env("INTEG_PERIODS", "30"))
    check(run_verilator(periods, 7), periods)
  end

  @tag :verilator
  test "Verilator replays the stimulus of the same run with identical outputs", %{res: res} do
    mod = Chains.rx_chain(tick_cycles: @tick, channels: @channels, depth: @depth, entries: @ncls)
    ExHdl.RTL.Cosim.assert_equivalent(mod, res.stim)
  end

  # development aid: INTEG_CACHE=1 keeps the (slow) simulation result between runs
  defp cached(key, fun) do
    path = Path.join(System.tmp_dir!(), "ex_aes67_#{key}.bin")

    cond do
      System.get_env("INTEG_CACHE") && File.exists?(path) ->
        path |> File.read!() |> :erlang.binary_to_term()

      System.get_env("INTEG_CACHE") ->
        res = fun.()
        File.write!(path, :erlang.term_to_binary(Map.delete(res, :mod)))
        res

      true ->
        fun.()
    end
  end

  @doc false
  def check(res, periods) do
    ev = res.events
    sent = Enum.reverse(res.state.sent)
    ticks = Enum.reverse(res.state.ticks)
    assert length(ticks) > periods + 3, "ticks: #{length(ticks)}"
    assert length(sent) > 0

    # the chain never lost a frame or stalled a stage
    assert Enum.all?(
             ev,
             &(&1.outs.stamp_stall == 0 and &1.outs.p_ovf == 0 and &1.outs.p_drop_full == 0)
           )

    assert Enum.all?(
             ev,
             &(&1.outs.p_dbg == 0 and &1.outs.jb_tick_overrun == 0 and &1.outs.ts_overflow == 0)
           )

    # every frame is sent between two ticks with margin
    for {i0, _, _, k} <- sent do
      {ti, _} = Enum.at(ticks, k)
      {tn, _} = Enum.at(ticks, k + 1)
      assert i0 > ti + 2 and i0 + 95 < tn, "frame at #{i0} in period #{k} (#{ti}..#{tn})"
    end

    # -- jitter buffer against the models --
    streams_in =
      for {_i0, _f, info, k} <- sent, info.kind == :rtp, not info.bad, do: {k, info.udp}

    arrivals = Enum.group_by(streams_in, &elem(&1, 0), &elem(&1, 1))
    {_, now0} = hd(ticks)

    jb0 = JitterBuffer.new(depth: @depth, channels: @channels, latency: @latency, now: now0)

    {frames_m, jb_m, dp_m} =
      ticks
      |> Enum.with_index()
      |> Enum.reduce({[], jb0, Depacketiser.new(entries())}, fn {{_, now}, k}, {frames, jb, dp} ->
        {jb, dp} =
          Enum.reduce(Map.get(arrivals, k - 1, []), {jb, dp}, fn {ip, port, bin}, {jb, dp} ->
            {dp, writes, _} = Depacketiser.process(dp, ip, port, bin)
            {jb, _} = JitterBuffer.write_all(jb, writes)
            {jb, dp}
          end)

        {jb, frame} = JitterBuffer.play(jb, now)
        {[frame | frames], jb, dp}
      end)

    frames_m = Enum.reverse(frames_m)
    frames_r = collect_jb(ev)
    n = min(length(frames_r), length(frames_m))
    assert n > periods
    assert Enum.take(frames_r, n) == Enum.take(frames_m, n)
    assert Enum.any?(frames_m, fn f -> Enum.any?(f, &(&1 != 0)) end), "no audio played"

    last = List.last(ev).outs

    for k <- [:written, :late, :overrun, :duplicate, :bad_channel],
        do: assert(last[:"jb_#{k}"] == jb_m.stats[k], "jb #{k}")

    assert last.rx_ok + last.rx_bad_rtp + last.rx_no_stream + last.rx_bad_length ==
             length(streams_in)

    assert last.rx_bad_rtp == dp_m.drops.bad_rtp
    assert last.rx_no_stream == dp_m.drops.no_stream

    # -- the media clock contract: rtp_ts = floor(t * rate) + offset of the wallclock model --
    wc0 = Wallclock.new(Timestamp.new(@sec, 0))

    for {{i, now}, _} <- Enum.zip(ticks, 1..length(ticks)) do
      w = Wallclock.advance(wc0, inc(), i - 5)
      t = Wallclock.time(w)
      want = ExPtp.MediaClock.rtp_timestamp(t, 48_000, @mc_offset)
      assert abs(Bitwise.band(now - want + 0x80000000, 0xFFFFFFFF) - 0x80000000) <= 1
    end

    # -- timestamps and PTP classification on every frame of the stamp stage --
    stamps = collect_stamp(ev)
    assert length(stamps) == length(sent)

    for {{bytes, tuser}, {i0, frame, info, _}} <- Enum.zip(stamps, sent) do
      m = Meta.unpack_tuser(tuser)
      mac_frame = frame
      assert bytes == mac_frame
      assert m.bad == info.bad
      cls = PtpDetect.classify(frame)
      assert m.ptp == cls.ptp
      if cls.ptp, do: assert({m.udp, m.message_type} == {cls.udp, cls.mtype})

      if info.kind == :ptp do
        assert m.ptp
        {:ok, msg} = decode_ptp(frame)
        assert msg.type == info.type
        assert m.message_type == Map.fetch!(%{sync: 0, delay_req: 1, follow_up: 8}, info.type)
      end

      # wallclock of the model at the capture event, minus the compensation
      assert m.ts_valid
      w = Wallclock.advance(wc0, inc(), i0 + @capture - 5)
      exp = TimestampUnit.compensate({w.seconds, w.nanoseconds, w.fraction}, comp())

      assert Meta.unpack_ts(m.ts) == exp,
             "frame at #{i0}: got #{inspect(Meta.unpack_ts(m.ts))} want #{inspect(exp)} (wallclock at the Start word #{inspect(Wallclock.advance(wc0, inc(), i0 - 5) |> Map.take([:seconds, :nanoseconds, :fraction]))})"
    end

    kinds = Enum.frequencies_by(sent, fn {_, _, info, _} -> {info.kind, info.bad} end)
    nonzero = frames_m |> List.flatten() |> Enum.count(&(&1 != 0))

    IO.puts(
      "rx chain: #{length(sent)} frames #{inspect(kinds)}, #{length(streams_in)} stream packets, " <>
        "#{length(ticks)} jitter buffer ticks, #{nonzero} non-silent samples played, " <>
        "stamps: #{length(stamps)}"
    )

    :ok
  end

  defp decode_ptp(frame) do
    {:ok, eth} = Ethernet.decode(frame)

    payload =
      if eth.ethertype == 0x88F7 do
        eth.payload
      else
        {:ok, ip} = IPv4.decode(eth.payload)
        {:ok, udp} = UDP.decode(ip.payload)
        udp.payload
      end

    Message.decode(payload)
  end
end
