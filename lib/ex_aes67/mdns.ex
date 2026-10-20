defmodule ExAes67.MDNS do
  @moduledoc """
  Minimal mDNS / DNS-SD responder and browser (RFC 6762, 6763) for RAVENNA
  session discovery.

  Options: `:port` (bind, default 5353), `:dest` (`{ip, port}` for multicast
  sends, default `{{224, 0, 0, 251}, 5353}`), `:join` (`{group, interface_ip}`,
  default none), `:name`.

  Responses go to `:dest` when the query came from port 5353 or had the QU
  bit, otherwise unicast to the sender (legacy unicast, RFC 6762 6.7, which is
  also what makes loopback tests work). Known-answer suppression, probing and
  conflict resolution are not implemented.

  A service is `%{instance: "Stage Box", type: "_rtsp._tcp", subtypes:
  ["_ravenna_session"], host: "stagebox", port: 554, txt: ["type=ravenna"],
  ip: {192, 168, 1, 5}}`. Browse a type or subtype with `browse/2`, for
  example `"_ravenna_session._sub._rtsp._tcp"`, and read the cache with
  `services/2`. Subscribers get `{:mdns, :found | :lost, service}`.

      {:ok, m} = ExAes67.MDNS.start_link(join: {{224, 0, 0, 251}, {192, 168, 1, 5}})
      ExAes67.MDNS.register(m, service)
      ExAes67.MDNS.browse(m, "_ravenna_session._sub._rtsp._tcp")
  """
  use GenServer
  alias ExAes67.DNS

  @enum "_services._dns-sd._udp.local"

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def register(server, service), do: GenServer.call(server, {:register, service})
  def unregister(server, instance), do: GenServer.call(server, {:unregister, instance})

  @doc "Starts browsing `type` (without `.local`) and sends a PTR query now."
  def browse(server, type), do: GenServer.call(server, {:browse, type})

  @doc "Sends a PTR query for `type` again."
  def query(server, type), do: GenServer.call(server, {:query, type})

  @doc "Resolved services for `type` in the cache."
  def services(server, type), do: GenServer.call(server, {:services, type})

  def subscribe(server, pid \\ self()), do: GenServer.call(server, {:subscribe, pid})
  def port(server), do: GenServer.call(server, :port)

  @impl true
  def init(opts) do
    sock_opts =
      [:binary, active: true, reuseaddr: true, multicast_loop: true, multicast_ttl: 255] ++
        case opts[:join] do
          nil ->
            [ip: {0, 0, 0, 0}]

          {group, iface} ->
            [ip: {0, 0, 0, 0}, add_membership: {group, iface}, multicast_if: iface]
        end

    with {:ok, sock} <- :gen_udp.open(Keyword.get(opts, :port, 5353), sock_opts) do
      {:ok,
       %{
         sock: sock,
         dest: Keyword.get(opts, :dest, {{224, 0, 0, 251}, 5353}),
         services: %{},
         browsing: MapSet.new(),
         cache: %{},
         subs: MapSet.new()
       }}
    else
      {:error, r} -> {:stop, r}
    end
  end

  @impl true
  def handle_call({:register, svc}, _from, st) do
    svc = Map.merge(%{subtypes: [], txt: [], ip: nil}, svc)
    st = put_in(st.services[svc.instance], svc)
    send_msg(st, st.dest, response(records(svc), []))
    {:reply, :ok, st}
  end

  def handle_call({:unregister, inst}, _from, st) do
    case Map.pop(st.services, inst) do
      {nil, _} ->
        {:reply, {:error, :unknown}, st}

      {svc, rest} ->
        goodbye = for r <- records(svc), do: %{r | ttl: 0}
        send_msg(st, st.dest, response(goodbye, []))
        {:reply, :ok, %{st | services: rest}}
    end
  end

  def handle_call({:browse, type}, from, st) do
    st = %{st | browsing: MapSet.put(st.browsing, type)}
    handle_call({:query, type}, from, st)
  end

  def handle_call({:query, type}, _from, st) do
    q = %DNS.Message{questions: [DNS.question(type <> ".local", :ptr)]}
    send_msg(st, st.dest, q)
    {:reply, :ok, st}
  end

  def handle_call({:services, type}, _from, st), do: {:reply, resolve(st, type <> ".local"), st}

  def handle_call({:subscribe, pid}, _from, st),
    do: {:reply, :ok, %{st | subs: MapSet.put(st.subs, pid)}}

  def handle_call(:port, _from, st), do: {:reply, elem(:inet.port(st.sock), 1), st}

  @impl true
  def handle_info({:udp, _, ip, port, data}, st) do
    case DNS.decode(data) do
      {:ok, %{response: false} = m} -> answer(st, m, {ip, port})
      {:ok, %{response: true} = m} -> {:noreply, ingest(st, m)}
      _ -> {:noreply, st}
    end
  end

  def handle_info(_, st), do: {:noreply, st}

  # responder

  defp answer(st, m, {_, src_port} = src) do
    {unicast, found} =
      Enum.reduce(m.questions, {false, []}, fn q, {u, acc} ->
        {u or q.unicast, acc ++ matches(st, String.downcase(q.name), q.type)}
      end)

    if found != [] do
      answers = Enum.uniq(for {a, _} <- found, do: a)
      extra = Enum.uniq(Enum.flat_map(found, &elem(&1, 1))) -- answers
      dest = if unicast or src_port != 5353, do: src, else: st.dest
      send_msg(st, dest, response(answers, extra))
    end

    {:noreply, st}
  end

  defp matches(st, name, type) do
    for {_, svc} <- st.services, hit <- hits(svc, name, type), do: hit
  end

  defp hits(svc, name, type) do
    [ptr, srv, txt, a | _] = records(svc)
    base = "#{svc.type}.local"
    subs = for s <- svc.subtypes, do: "#{s}._sub.#{base}"
    fq = String.downcase(srv.name)
    host = String.downcase(a.name)
    t = fn types -> type in types end

    cond do
      name == @enum and t.([:ptr, :any]) ->
        [{DNS.record(@enum, :ptr, base, 4500), []}]

      (name == base or name in Enum.map(subs, &String.downcase/1)) and t.([:ptr, :any]) ->
        owner = if name == base, do: ptr, else: %{ptr | name: name}
        [{owner, [srv, txt, a]}]

      name == fq and t.([:srv, :txt, :any]) ->
        for r <- [srv, txt], t.([r.type, :any]), do: {r, [a]}

      name == host and t.([:a, :any]) ->
        [{a, []}]

      true ->
        []
    end
  end

  defp records(svc) do
    base = "#{svc.type}.local"
    fq = "#{svc.instance}.#{base}"
    host = "#{svc.host}.local"

    [
      DNS.record(base, :ptr, fq, 4500),
      DNS.record(fq, :srv, {0, 0, svc.port, host}, 120, cache_flush: true),
      DNS.record(fq, :txt, svc.txt, 4500, cache_flush: true),
      DNS.record(host, :a, svc.ip || {0, 0, 0, 0}, 120, cache_flush: true)
    ] ++
      for(s <- svc.subtypes, do: DNS.record("#{s}._sub.#{base}", :ptr, fq, 4500))
  end

  defp response(answers, extra),
    do: %DNS.Message{response: true, authoritative: true, answers: answers, additional: extra}

  defp send_msg(st, {ip, port}, msg), do: :gen_udp.send(st.sock, ip, port, DNS.encode(msg))

  # browser

  defp ingest(st, m) do
    now = System.monotonic_time(:millisecond)
    recs = m.answers ++ m.additional

    {cache, events} =
      Enum.reduce(recs, {st.cache, []}, fn r, {c, ev} ->
        key =
          {r.type, String.downcase(r.name),
           if(r.type == :ptr, do: String.downcase(r.data), else: nil)}

        cond do
          r.type not in [:ptr, :srv, :txt, :a] ->
            {c, ev}

          r.ttl == 0 ->
            {Map.delete(c, key), if(r.type == :ptr, do: [{:lost, r} | ev], else: ev)}

          true ->
            new? = r.type == :ptr and not Map.has_key?(c, key)

            {Map.put(c, key, {r.data, now + r.ttl * 1000}),
             if(new?, do: [{:found, r} | ev], else: ev)}
        end
      end)

    st = %{st | cache: cache}

    for {kind, r} <- Enum.reverse(events),
        svc <- resolve(st, r.name, r.data) |> then(&if(&1 == [], do: [stub(r)], else: &1)),
        pid <- st.subs,
        do: send(pid, {:mdns, kind, svc})

    st
  end

  defp stub(r),
    do: %{instance: instance(r.data), fqdn: r.data, host: nil, port: nil, txt: [], addrs: []}

  defp resolve(st, owner, only \\ nil) do
    now = System.monotonic_time(:millisecond)
    owner = String.downcase(owner)
    live = for {{t, n, tgt}, {d, exp}} <- st.cache, exp > now, do: {t, n, tgt, d}

    for {:ptr, ^owner, tgt, fq} <- live,
        only == nil or fq == only,
        {:srv, ^tgt, _, {_, _, port, host}} <- live do
      txt = Enum.find_value(live, [], fn {t, n, _, d} -> (t == :txt and n == tgt) && d end)
      addrs = for {:a, n, _, ip} <- live, n == String.downcase(host), do: ip
      %{instance: instance(fq), fqdn: fq, host: host, port: port, txt: txt, addrs: addrs}
    end
  end

  defp instance(fqdn), do: fqdn |> String.split("._", parts: 2) |> hd()
end
