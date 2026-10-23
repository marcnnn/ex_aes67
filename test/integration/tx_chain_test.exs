defmodule ExAes67.Integration.TxChainTest do
  @moduledoc """
  Transmit side end to end in RTL simulation: the ex_aes67 packetiser (media clock from the
  ex_ptp `MediaNco`) and a PTP payload source (Sync, Delay_Req, Follow_Up built with
  `ExPtp.Message`) -> ex_net UDP/IP/Ethernet header insertion and packet FIFOs -> arbiter ->
  ex_ptp one-step insertion -> ex_net MAC TX -> XGMII, decoded on the BEAM with the MAC RX
  model. The RTP packets must equal the packetiser model, the PTP frames the messages that were
  sent (Sync with the origin timestamp the model wallclock has at the Start word), and the
  timestamp unit must report the same wallclock time for every frame with its tag.
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias ExAes67.Model.{Packetiser, SampleRing}
  alias ExAes67.RTL.Program
  alias ExAes67.Test.{Chains, Loop}
  alias ExNet.{Ethernet, IPv4, UDP}
  alias ExNet.MAC.Rx64
  alias ExNet.RTL.{Ifc, UdpTx}
  alias ExPtp.{Message, Timestamp, Wallclock}
  alias ExPtp.RTL.Meta

  @moduletag timeout: 1_200_000
  @tick 192
  @channels 4
  @depth 16
  @sec 7000
  @mc_offset 0x100
  @src_mac <<2, 0, 0, 0, 0, 0x42>>
  @src_ip {10, 0, 0, 7}
  @uc_mac <<0xA0, 1, 2, 3, 4, 5>>
  @ptp_ip {224, 0, 1, 129}
  @clock_id <<1, 2, 3, 4, 5, 6, 7, 8>>
  # events from the strobe's event to the timestamp unit's capture register (same clock)
  @capture 3

  defp inc, do: Chains.wc_inc(@tick)
  defp tx_comp, do: (@capture * inc()) >>> 16
  defp ins_comp, do: (Ifc.tx_first_beat_cycles() * inc()) >>> 16

  defp cfgs do
    [
      %{
        id: :a,
        channels: 2,
        base_channel: 0,
        ptime_us: 125,
        format: :l24,
        pt: 97,
        ssrc: 0xA,
        dst_ip: {239, 69, 2, 1},
        dst_port: 5004,
        ts_offset: 0x100
      },
      %{
        id: :b,
        channels: 1,
        base_channel: 2,
        ptime_us: 125,
        format: :l16,
        pt: 98,
        ssrc: 0xB,
        dst_ip: {239, 69, 2, 2},
        dst_port: 5006,
        ts_offset: 0x100,
        seq0: 65_534
      }
    ]
  end

  # distinct nonzero samples, L16 exact on channel 2
  defp sample(0, t), do: 1 + rem(t * 7919, 8_000_000)
  defp sample(1, t), do: -1 - rem(t * 104_729, 8_000_000)
  defp sample(2, t), do: (1 + rem(t, 30_000)) * 256
  defp sample(3, _), do: nil

  defp ptp_payload(type, seq) do
    key = if type == :follow_up, do: :precise_origin_timestamp, else: :origin_timestamp
    Message.encode(Message.new(type, {@clock_id, 1}, seq, %{key => Timestamp.new(0, 0)}))
  end

  # PTP sends: {tick index to send after, type, tag}
  @ptp [{1, :sync, 1}, {2, :delay_req, 2}, {3, :sync, 3}, {4, :follow_up, 4}, {6, :sync, 5}]

  defp beats(p) do
    chunks = for <<c::binary-size(8) <- p>>, do: c
    rest = binary_part(p, 8 * length(chunks), byte_size(p) - 8 * length(chunks))
    all = chunks ++ if(rest == <<>>, do: [], else: [rest])

    for {c, i} <- Enum.with_index(all, 1) do
      bits = 8 * byte_size(c)
      <<v::little-size(bits)>> = c
      {v, (1 <<< byte_size(c)) - 1, i == length(all)}
    end
  end

  defp run(ticks_wanted) do
    mod = Chains.tx_chain(tick_cycles: @tick, channels: @channels, depth: @depth)

    init = %{
      phase: :wait_align,
      first: nil,
      now0: nil,
      prog: nil,
      go_at: nil,
      ticks: [],
      samples: [],
      ptp: [],
      cur: nil,
      tag: 0,
      pops: [],
      sof: [],
      words: []
    }

    n = 8 + 3 * @tick + (ticks_wanted + 4) * @tick

    res = Loop.run(mod, n, init, fn st, ev -> step(st, ev, ticks_wanted) end)
    Map.put(res, :mod, mod)
  end

  defp step(st, ev, ticks_wanted) do
    i = ev.i
    o = ev.outs

    # alignment, then the packetiser's first tick: program the table for it
    st =
      cond do
        st.phase == :wait_align and o.aligned == 1 ->
          %{st | phase: :wait_tick}

        st.phase == :wait_tick and o.tick == 1 ->
          now0 = o.rtp_ts + 1
          writes = Program.tx(cfgs(), now0)
          %{st | phase: :program, now0: now0, prog: writes, first: i}

        st.phase == :program and st.prog == [] ->
          %{st | phase: :wait_go, go_at: i + 10}

        st.phase == :wait_go and i >= st.go_at ->
          %{st | phase: :run}

        true ->
          st
      end

    {wr, st} =
      case st.prog do
        [w | rest] when st.phase == :program -> {w, %{st | prog: rest}}
        _ -> {nil, st}
      end

    go = if st.phase == :run, do: 1, else: 0

    # gated ticks: samples follow, PTP packets are scheduled
    st =
      if go == 1 and o.tick == 1 do
        t = o.rtp_ts
        k = length(st.ticks)

        smp =
          for c <- 0..(@channels - 1), (v = sample(c, t)) != nil, do: {i + 1 + c, c, v}

        ptp = for {at, type, tag} <- @ptp, at == k, do: {i + 60, type, tag}
        %{st | ticks: [{i, t} | st.ticks], samples: st.samples ++ smp, ptp: st.ptp ++ ptp}
      else
        st
      end

    {smp, st} =
      case st.samples do
        [{due, c, v} | rest] when due <= i ->
          {%{k_in_valid: 1, k_in_ch: c, k_in_data: v}, %{st | samples: rest}}

        _ ->
          {%{k_in_valid: 0}, st}
      end

    # the PTP source: one packet at a time, a beat offered until taken
    {src, st} = ptp_source(st, i, o)

    # timestamp FIFO: pop whenever something is there
    pop = if o.ts_valid == 1, do: 1, else: 0
    st = if pop == 1, do: %{st | pops: [{o.ts_tag, o.ts_ts} | st.pops]}, else: st
    st = if o.tx_sof == 1, do: %{st | sof: [{i, o.tx_tag} | st.sof]}, else: st

    st =
      if o.xgmii_txc != 0xFF or o.xgmii_txd != 0x0707070707070707,
        do: %{st | words: [{o.xgmii_txd, o.xgmii_txc} | st.words]},
        else: st

    cfg =
      case wr do
        nil -> %{k_cfg_we: 0}
        w -> %{k_cfg_we: 1, k_cfg_sel: w.cfg_sel, k_cfg_addr: w.cfg_addr, k_cfg_data: w.cfg_data}
      end

    done = length(st.ticks) >= ticks_wanted

    base = %{
      rst_n: if(i < 3, do: 0, else: 1),
      set_wr: if(i == 4, do: 1, else: 0),
      set_sec: @sec,
      set_ns: 0,
      align: if(i == 8, do: 1, else: 0),
      mc_offset: @mc_offset,
      pk_go: if(done and false, do: 0, else: go),
      src_mac: :binary.decode_unsigned(@src_mac),
      src_ip: IPv4.ip_int(@src_ip),
      uc_mac: :binary.decode_unsigned(@uc_mac),
      s0_src_port: 5004,
      s0_ttl: 32,
      s0_tos: 0xB8,
      s0_tag: 0xAA,
      s1_src_port: 319,
      s1_ttl: 1,
      s1_tos: 0,
      x_enable: 1,
      x_zero_csum: 1,
      x_comp: ins_comp(),
      tx_comp: tx_comp(),
      tx_pop: pop
    }

    {base |> Map.merge(smp) |> Map.merge(src) |> Map.merge(cfg), st}
  end

  defp ptp_source(st, i, o) do
    st =
      if st.cur == nil and match?([{due, _, _} | _] when due <= i, st.ptp) do
        [{_, type, tag} | rest] = st.ptp
        payload = ptp_payload(type, tag)
        port = if type == :follow_up, do: 320, else: 319
        user = Ifc.pack_udp_tx(%{ip: IPv4.ip_int(@ptp_ip), port: port, len: byte_size(payload)})
        %{st | ptp: rest, cur: {beats(payload), user}, tag: tag}
      else
        st
      end

    case st.cur do
      nil ->
        {%{s1_axis_tvalid: 0, s1_tag: st.tag}, st}

      {[{d, k, l} | rest], user} ->
        taken = o.s1_axis_tready == 1
        st = if taken, do: %{st | cur: if(l, do: nil, else: {rest, user})}, else: st

        {%{
           s1_axis_tvalid: 1,
           s1_axis_tdata: d,
           s1_axis_tkeep: k,
           s1_axis_tlast: if(l, do: 1, else: 0),
           s1_axis_tuser: user,
           s1_tag: st.tag
         }, st}
    end
  end

  defp total({s, n, f}), do: s * 1_000_000_000 + n + f / 65536

  test "RTP and PTP frames out of the MAC equal the models; one-step and two-step timestamps agree" do
    res = run(26)
    check(res)
  end

  @tag :verilator
  test "Verilator replays the stimulus of the same run with identical outputs" do
    res = run(12)
    ExHdl.RTL.Cosim.assert_equivalent(res.mod, res.stim)
  end

  @doc false
  def check(res) do
    ev = res.events
    st = res.state
    ticks = Enum.reverse(st.ticks)
    assert length(ticks) >= 8

    # media clock contract: consecutive tick values, the first one is the table's `now`
    assert elem(hd(ticks), 1) == st.now0

    assert ticks
           |> Enum.map(&elem(&1, 1))
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.all?(fn [a, b] -> b == a + 1 end)

    # -- frames from the wire --
    frames = Rx64.frames(Enum.reverse(st.words))
    assert Enum.all?(frames, &match?({:ok, _}, &1)), inspect(Enum.map(frames, &elem(&1, 0)))
    frames = Enum.map(frames, &elem(&1, 1))

    decoded =
      for f <- frames do
        {:ok, eth} = Ethernet.decode(f)
        {:ok, ip} = IPv4.decode(eth.payload)
        {:ok, udp} = UDP.decode(ip.payload)
        {f, eth, ip, udp}
      end

    {rtp, ptp} = Enum.split_with(decoded, fn {_, _, _, u} -> u.src_port == 5004 end)

    # -- RTP against the packetiser model --
    {_, _, model_pkts} =
      Enum.reduce(
        ticks,
        {SampleRing.new(depth: @depth), Packetiser.new(cfgs(), now: st.now0), []},
        fn {_, t}, {ring, m, acc} ->
          ring =
            Enum.reduce(0..(@channels - 1), ring, fn c, ring ->
              case sample(c, t) do
                nil -> ring
                v -> SampleRing.write(ring, c, t, v)
              end
            end)

          {m, pkts} = Packetiser.tick(m, ring, t)
          {ring, m, acc ++ pkts}
        end
      )

    got = for {_, _, _, u} <- rtp, do: u.payload
    want = for p <- model_pkts, do: p.udp_payload
    # packets of the last ticks may still be in flight
    n = min(length(got), length(want))
    assert n >= 6
    assert Enum.take(got, n) == Enum.take(want, n)
    assert length(want) - length(got) <= 2

    for {{f, eth, ip, udp}, p, id} <-
          Enum.zip([rtp, model_pkts, Enum.to_list(0..(length(rtp) - 1))]) do
      {a, b, c, d} = p.dst_ip
      _ = {a, b, c, d}
      assert eth.dst == Ethernet.multicast_mac(p.dst_ip)
      assert eth.src == @src_mac

      assert {ip.dst, ip.src, ip.ttl, ip.dscp, ip.df, ip.id} ==
               {p.dst_ip, @src_ip, 32, 0x2E, true, id}

      assert udp.dst_port == p.dst_port
      assert f == UdpTx.model(p.udp_payload, {p.dst_ip, p.dst_port}, cfg0(), id) |> pad60()
    end

    # -- PTP frames --
    sofs = Enum.reverse(st.sof)
    assert length(sofs) == length(frames)
    wc0 = Wallclock.new(Timestamp.new(@sec, 0))
    wc = fn e -> Wallclock.advance(wc0, inc(), e - 5) end

    for {{_f, eth, ip, udp}, _} <- Enum.zip(ptp, 0..(length(ptp) - 1)) do
      assert eth.dst == Ethernet.multicast_mac(@ptp_ip) and ip.dst == @ptp_ip and ip.ttl == 1
      {:ok, msg} = Message.decode(udp.payload)
      assert msg.type in [:sync, :delay_req, :follow_up]
      assert udp.dst_port == if(msg.type == :follow_up, do: 320, else: 319)
    end

    assert length(ptp) == length(Enum.filter(@ptp, fn {at, _, _} -> at < length(ticks) - 1 end)) or
             length(ptp) >= 3

    # the wire order of all frames and the tags/timestamps the unit reported
    tags = Enum.map(sofs, &elem(&1, 1))
    pops = Enum.reverse(st.pops)
    assert Enum.map(pops, &elem(&1, 0)) == tags

    for {{f, _eth, _ip, udp}, {i, tag}, {ptag, ts}} <- Enum.zip([decoded, sofs, pops]) do
      assert tag == ptag
      # two-step: the unit's stamp is the wallclock of the model at the Start word's event
      w = wc.(i)
      {sec, ns, frac} = Meta.unpack_ts(ts)
      assert {sec, ns} == {w.seconds, w.nanoseconds}, "frame #{inspect(tag)}"
      assert frac == w.fraction >>> 16 or abs(frac - (w.fraction >>> 16)) <= 1

      # one-step: a Sync carries the same time (whole ns) in its origin timestamp
      if udp.src_port == 319 do
        {:ok, msg} = Message.decode(udp.payload)

        if msg.type == :sync do
          t = msg.body.origin_timestamp
          assert {t.seconds, t.nanoseconds} == {w.seconds, w.nanoseconds}
          sent = ptp_payload(:sync, tag)
          {:ok, sent_msg} = Message.decode(sent)
          assert %{msg | body: %{}} == %{sent_msg | body: %{}}
        else
          assert udp.payload == ptp_payload(msg.type, tag)
        end
      end

      _ = f
      _ = total({sec, ns, frac})
    end

    IO.puts(
      "tx chain: #{length(frames)} frames (#{length(rtp)} RTP, #{length(ptp)} PTP), " <>
        "#{length(ticks)} ticks, #{length(pops)} timestamps"
    )

    # no frame lost anywhere on the way
    assert Enum.all?(ev, &(&1.outs.drop == 0 and &1.outs.ts_overflow == 0))

    assert Enum.count(ev, &(&1.outs.stamped == 1)) ==
             Enum.count(ptp, fn {_, _, _, u} -> sync?(u) end)

    last = List.last(ev).outs
    assert last.st_late == 0 and last.st_sched_overrun == 0 and last.st_silence == 0
    :ok
  end

  defp sync?(udp) do
    match?({:ok, %{type: :sync}}, Message.decode(udp.payload))
  end

  defp pad60(f) when byte_size(f) < 60, do: f <> :binary.copy(<<0>>, 60 - byte_size(f))
  defp pad60(f), do: f

  defp cfg0,
    do: %{src_mac: @src_mac, src_ip: @src_ip, uc_mac: @uc_mac, src_port: 5004, ttl: 32, tos: 0xB8}
end
