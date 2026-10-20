defmodule ExAes67.SAP.Server do
  @moduledoc """
  SAP announcer, listener and session directory.

  Options: `:port` (bind, default 9875), `:dest` (`{ip, port}` for sends,
  default `{{239, 255, 255, 255}, 9875}`), `:join` (`{group, interface_ip}` to
  join, default none, enable for real multicast), `:origin` (IP put in sent
  packets, default `{127, 0, 0, 1}`), `:interval` (announce period in ms,
  default 30_000), `:timeout` (drop silent sessions after ms, default
  `10 * interval`), `:sweep` (expiry check period, default 5_000), `:name`.

  Events are sent to subscribers as
  `{:sap, :announce | :delete | :timeout, %{key: key, sdp: text, origin: ip}}`.

      {:ok, sap} = ExAes67.SAP.Server.start_link(join: {{239, 255, 255, 255}, {192, 168, 1, 5}}, origin: {192, 168, 1, 5})
      ExAes67.SAP.Server.announce(sap, "ch1", sdp_text)
      ExAes67.SAP.Server.sessions(sap)
  """
  use GenServer
  alias ExAes67.SAP

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Starts announcing `sdp` under a local `id`; sends immediately and then every interval."
  def announce(server, id, sdp), do: GenServer.call(server, {:announce, id, sdp})

  @doc "Sends a deletion for local session `id` and stops announcing it."
  def withdraw(server, id), do: GenServer.call(server, {:withdraw, id})

  @doc "Session directory: list of `%{key: {origin, msg_id}, origin:, sdp:, parsed:, seen:}`."
  def sessions(server), do: GenServer.call(server, :sessions)

  def subscribe(server, pid \\ self()), do: GenServer.call(server, {:subscribe, pid})

  @doc "Local UDP port."
  def port(server), do: GenServer.call(server, :port)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, 30_000)

    sock_opts =
      [:binary, active: true, reuseaddr: true, multicast_loop: true, multicast_ttl: 255] ++
        case opts[:join] do
          nil -> [ip: {0, 0, 0, 0}]
          {group, iface} -> [ip: group, add_membership: {group, iface}, multicast_if: iface]
        end

    case :gen_udp.open(Keyword.get(opts, :port, 9875), sock_opts) do
      {:ok, sock} ->
        sweep = Keyword.get(opts, :sweep, 5_000)
        Process.send_after(self(), :sweep, sweep)

        {:ok,
         %{
           sock: sock,
           dest: Keyword.get(opts, :dest, {{239, 255, 255, 255}, 9875}),
           origin: Keyword.get(opts, :origin, {127, 0, 0, 1}),
           interval: interval,
           timeout: Keyword.get(opts, :timeout, 10 * interval),
           sweep: sweep,
           own: %{},
           dir: %{},
           subs: MapSet.new()
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:announce, id, sdp}, _from, st) do
    case st.own[id] do
      %{msg_id: old, sdp: prev} when prev != sdp -> send_pkt(st, :delete, old, prev)
      _ -> :ok
    end

    mid = SAP.msg_id(sdp)
    if st.own[id][:timer], do: Process.cancel_timer(st.own[id].timer)
    send_pkt(st, :announce, mid, sdp)
    timer = Process.send_after(self(), {:resend, id}, st.interval)
    {:reply, mid, put_in(st.own[id], %{msg_id: mid, sdp: sdp, timer: timer})}
  end

  def handle_call({:withdraw, id}, _from, st) do
    case Map.pop(st.own, id) do
      {nil, _} ->
        {:reply, {:error, :unknown}, st}

      {o, own} ->
        Process.cancel_timer(o.timer)
        send_pkt(st, :delete, o.msg_id, o.sdp)
        {:reply, :ok, %{st | own: own}}
    end
  end

  def handle_call(:sessions, _from, st) do
    list = for {key, e} <- st.dir, do: Map.put(e, :key, key)
    {:reply, Enum.sort_by(list, & &1.key), st}
  end

  def handle_call({:subscribe, pid}, _from, st),
    do: {:reply, :ok, %{st | subs: MapSet.put(st.subs, pid)}}

  def handle_call(:port, _from, st), do: {:reply, :inet.port(st.sock) |> elem(1), st}

  @impl true
  def handle_info({:resend, id}, st) do
    case st.own[id] do
      nil ->
        {:noreply, st}

      o ->
        send_pkt(st, :announce, o.msg_id, o.sdp)

        {:noreply,
         put_in(st.own[id].timer, Process.send_after(self(), {:resend, id}, st.interval))}
    end
  end

  def handle_info({:udp, _, _, _, data}, st) do
    with {:ok, %{payload_type: "application/sdp"} = p} <- SAP.decode(data),
         false <- own?(st, p) do
      {:noreply, receive_pkt(st, p)}
    else
      _ -> {:noreply, st}
    end
  end

  def handle_info(:sweep, st) do
    now = System.monotonic_time(:millisecond)
    {dead, live} = Enum.split_with(st.dir, fn {_, e} -> now - e.seen > st.timeout end)
    Enum.each(dead, fn {key, e} -> notify(st, :timeout, key, e) end)
    Process.send_after(self(), :sweep, st.sweep)
    {:noreply, %{st | dir: Map.new(live)}}
  end

  def handle_info(_, st), do: {:noreply, st}

  defp own?(st, p),
    do: p.origin == st.origin and Enum.any?(st.own, fn {_, o} -> o.msg_id == p.msg_id end)

  defp receive_pkt(st, %{type: :announce} = p) do
    key = {p.origin, p.msg_id}

    parsed =
      case ExAes67.SDP.parse(p.payload) do
        {:ok, s} -> s
        _ -> nil
      end

    e = %{
      origin: p.origin,
      sdp: p.payload,
      parsed: parsed,
      seen: System.monotonic_time(:millisecond)
    }

    if not Map.has_key?(st.dir, key), do: notify(st, :announce, key, e)
    %{st | dir: Map.put(st.dir, key, e)}
  end

  defp receive_pkt(st, %{type: :delete} = p) do
    key = {p.origin, p.msg_id}

    case Map.pop(st.dir, key) do
      {nil, _} ->
        st

      {e, dir} ->
        notify(st, :delete, key, e)
        %{st | dir: dir}
    end
  end

  defp notify(st, ev, key, e) do
    for pid <- st.subs, do: send(pid, {:sap, ev, %{key: key, sdp: e.sdp, origin: e.origin}})
  end

  defp send_pkt(st, type, mid, sdp) do
    pkt = SAP.encode(%{type: type, msg_id: mid, origin: st.origin, payload: sdp})
    {ip, port} = st.dest
    :gen_udp.send(st.sock, ip, port, pkt)
  end
end
