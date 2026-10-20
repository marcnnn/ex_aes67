defmodule ExAes67.DiscoveryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias ExAes67.{DNS, MDNS, RTSP, SAP}
  alias ExAes67.SAP.Server

  @sdp "v=0\r\no=- 1 1 IN IP4 10.0.0.1\r\ns=Test\r\nc=IN IP4 239.1.1.1/32\r\nt=0 0\r\nm=audio 5004 RTP/AVP 97\r\na=rtpmap:97 L24/48000/2\r\n"

  describe "SAP codec" do
    test "known bytes" do
      bin = SAP.encode(%{type: :announce, msg_id: 0xABCD, origin: {1, 2, 3, 4}, payload: "v=0"})
      assert bin == <<0x20, 0, 0xAB, 0xCD, 1, 2, 3, 4, "application/sdp", 0, "v=0">>
      assert {:ok, %{type: :delete}} = SAP.decode(<<0x24, 0, 0, 1, 1, 2, 3, 4, "v=0">>)
    end

    test "legacy payload without mime type, auth data and ipv6" do
      assert {:ok, %{payload_type: "application/sdp", payload: "v=0\r\n", origin: {1, 2, 3, 4}}} =
               SAP.decode(<<0x20, 1, 0, 9, 1, 2, 3, 4, 0xAA, 0xBB, 0xCC, 0xDD, "v=0\r\n">>)

      pkt = %{
        type: :announce,
        msg_id: 5,
        origin: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1},
        payload: @sdp
      }

      assert {:ok, %{origin: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, payload: @sdp}} =
               pkt |> SAP.encode() |> SAP.decode()
    end

    test "errors" do
      assert {:error, :encrypted} = SAP.decode(<<0x22, 0, 0, 1, 1, 2, 3, 4>>)
      assert {:error, :compressed} = SAP.decode(<<0x21, 0, 0, 1, 1, 2, 3, 4>>)
      assert {:error, :bad_version} = SAP.decode(<<0x40, 0, 0, 1, 1, 2, 3, 4>>)
      assert {:error, :truncated} = SAP.decode(<<0x20, 0, 0>>)
      assert {:error, :truncated} = SAP.decode(<<0x20, 3, 0, 1, 1, 2, 3, 4, 0>>)
    end

    property "round trip" do
      check all type <- member_of([:announce, :delete]),
                id <- integer(0..65_535),
                origin <-
                  tuple({integer(0..255), integer(0..255), integer(0..255), integer(0..255)}),
                payload <- binary(max_length: 200) do
        p = %{type: type, msg_id: id, origin: origin, payload: payload}
        {:ok, back} = p |> SAP.encode() |> SAP.decode()
        assert Map.take(back, [:type, :msg_id, :origin, :payload]) == p
      end
    end

    test "msg_id is non-zero and content dependent" do
      assert SAP.msg_id(@sdp) in 1..65_535
      assert SAP.msg_id(@sdp) != SAP.msg_id(@sdp <> "a=x\r\n")
    end
  end

  describe "SAP server on loopback" do
    test "announce, directory, delete, timeout" do
      {:ok, listener} =
        Server.start_link(port: 0, origin: {127, 0, 0, 9}, timeout: 150, sweep: 30)

      port = Server.port(listener)
      Server.subscribe(listener)

      {:ok, ann} =
        Server.start_link(
          port: 0,
          dest: {{127, 0, 0, 1}, port},
          origin: {127, 0, 0, 2},
          interval: 40
        )

      mid = Server.announce(ann, "s1", @sdp)

      assert_receive {:sap, :announce, %{key: {{127, 0, 0, 2}, ^mid}, sdp: @sdp}}, 1000
      assert [%{parsed: %ExAes67.SDP{name: "Test"}, sdp: @sdp}] = Server.sessions(listener)

      # periodic re-announcement keeps it alive beyond the timeout
      Process.sleep(300)
      assert [_] = Server.sessions(listener)

      assert :ok = Server.withdraw(ann, "s1")
      assert_receive {:sap, :delete, %{key: {{127, 0, 0, 2}, ^mid}}}, 1000
      assert [] = Server.sessions(listener)
      assert {:error, :unknown} = Server.withdraw(ann, "s1")

      # silent sessions expire
      {:ok, ann2} =
        Server.start_link(
          port: 0,
          dest: {{127, 0, 0, 1}, port},
          origin: {127, 0, 0, 3},
          interval: 60_000
        )

      Server.announce(ann2, "x", @sdp)
      assert_receive {:sap, :announce, _}, 1000
      assert_receive {:sap, :timeout, _}, 1000
      assert [] = Server.sessions(listener)
    end

    test "changed SDP replaces the old announcement" do
      {:ok, l} = Server.start_link(port: 0, origin: {127, 0, 0, 9})
      Server.subscribe(l)

      {:ok, a} =
        Server.start_link(port: 0, dest: {{127, 0, 0, 1}, Server.port(l)}, origin: {127, 0, 0, 2})

      m1 = Server.announce(a, "s", @sdp)
      new = String.replace(@sdp, "Test", "Renamed")
      m2 = Server.announce(a, "s", new)
      assert m1 != m2
      assert_receive {:sap, :delete, %{key: {_, ^m1}}}, 1000
      assert_receive {:sap, :announce, %{key: {_, ^m2}}}, 1000
      assert [%{key: {_, ^m2}}] = Server.sessions(l)
    end

    @tag :multicast
    test "real multicast group" do
      group = {239, 255, 255, 255}
      join = {group, {127, 0, 0, 1}}
      {:ok, a} = Server.start_link(join: join, origin: {127, 0, 0, 2})
      {:ok, b} = Server.start_link(join: join, origin: {127, 0, 0, 3})
      Server.subscribe(b)
      Server.announce(a, "m", @sdp)
      assert_receive {:sap, :announce, _}, 2000
    end
  end

  describe "DNS codec" do
    test "compression pointers on decode" do
      # question "a.local" A, answer name is a pointer to offset 12
      msg =
        <<1::16, 0x84, 0, 1::16, 1::16, 0::32, 1, ?a, 5, "local", 0, 1::16, 1::16, 0xC0, 12,
          1::16, 0x8001::16, 120::32, 4::16, 10, 0, 0, 1>>

      assert {:ok,
              %{
                questions: [%{name: "a.local", type: :a}],
                answers: [r],
                response: true,
                authoritative: true
              }} = DNS.decode(msg)

      assert %{name: "a.local", data: {10, 0, 0, 1}, cache_flush: true, ttl: 120} = r
    end

    test "all record types round trip with compression" do
      m = %DNS.Message{
        id: 7,
        response: true,
        authoritative: true,
        questions: [%{DNS.question("_rtsp._tcp.local", :ptr, unicast: true) | class: 1}],
        answers: [
          DNS.record("_rtsp._tcp.local", :ptr, "Box._rtsp._tcp.local", 4500),
          DNS.record("_ravenna_session._sub._rtsp._tcp.local", :ptr, "Box._rtsp._tcp.local", 4500)
        ],
        additional: [
          DNS.record("Box._rtsp._tcp.local", :srv, {0, 0, 554, "box.local"}, 120,
            cache_flush: true
          ),
          DNS.record("Box._rtsp._tcp.local", :txt, ["type=ravenna", "x="], 4500),
          DNS.record("Box._rtsp._tcp.local", :txt, [], 4500),
          DNS.record("box.local", :a, {192, 168, 1, 5}, 120),
          DNS.record("box.local", :aaaa, {0xFE80, 0, 0, 0, 1, 2, 3, 4}, 120),
          DNS.record("box.local", 99, <<1, 2, 3>>, 5)
        ]
      }

      bin = DNS.encode(m)
      assert {:ok, ^m} = DNS.decode(bin)
      uncompressed = m.answers |> Enum.map(&byte_size(&1.name)) |> Enum.sum()
      assert byte_size(bin) < 400 + uncompressed
      assert :binary.matches(bin, "_rtsp") |> length() <= 2
    end

    test "malformed input" do
      assert {:error, :truncated} = DNS.decode(<<1, 2, 3>>)
      # pointer loop
      loop = <<0::16, 0::16, 1::16, 0::48, 0xC0, 12, 1::16, 1::16>>
      assert {:error, :malformed} = DNS.decode(loop)
      assert {:error, :malformed} = DNS.decode(<<0::16, 0::16, 1::16, 0::48, 5, "ab">>)
    end

    property "records round trip" do
      label = string(?a..?z, min_length: 1, max_length: 10)
      name = gen(all ls <- list_of(label, min_length: 1, max_length: 4), do: Enum.join(ls, "."))

      check all n <- name,
                target <- name,
                port <- integer(0..65_535),
                ip <- tuple({byte(), byte(), byte(), byte()}),
                txt <-
                  list_of(binary(min_length: 1, max_length: 20), min_length: 1, max_length: 3) do
        recs = [
          DNS.record(n, :srv, {1, 2, port, target}, 10),
          DNS.record(target, :a, ip, 20),
          DNS.record(n, :txt, txt, 30),
          DNS.record(n, :ptr, target, 40)
        ]

        m = %DNS.Message{response: true, answers: recs}
        assert {:ok, ^m} = m |> DNS.encode() |> DNS.decode()
      end
    end
  end

  describe "mDNS over loopback unicast" do
    test "responder answers RAVENNA browse, browser caches and resolves" do
      {:ok, resp} = MDNS.start_link(port: 0)

      svc = %{
        instance: "Stage Box",
        type: "_rtsp._tcp",
        subtypes: ["_ravenna_session"],
        host: "stagebox",
        port: 8554,
        txt: ["type=ravenna"],
        ip: {192, 168, 1, 5}
      }

      MDNS.register(resp, svc)
      {:ok, br} = MDNS.start_link(port: 0, dest: {{127, 0, 0, 1}, MDNS.port(resp)})
      MDNS.subscribe(br)
      MDNS.browse(br, "_ravenna_session._sub._rtsp._tcp")

      assert_receive {:mdns, :found,
                      %{instance: "Stage Box", port: 8554, host: "stagebox.local"} = found},
                     1000

      assert found.addrs == [{192, 168, 1, 5}]
      assert found.txt == ["type=ravenna"]
      assert [^found] = MDNS.services(br, "_ravenna_session._sub._rtsp._tcp")
    end

    test "plain _rtsp._tcp, no match, goodbye" do
      {:ok, resp} = MDNS.start_link(port: 0)

      MDNS.register(resp, %{
        instance: "A",
        type: "_rtsp._tcp",
        host: "a",
        port: 554,
        ip: {10, 0, 0, 1}
      })

      {:ok, br} = MDNS.start_link(port: 0, dest: {{127, 0, 0, 1}, MDNS.port(resp)})
      MDNS.subscribe(br)

      MDNS.browse(br, "_http._tcp")
      refute_receive {:mdns, _, _}, 150
      MDNS.browse(br, "_ravenna_session._sub._rtsp._tcp")
      refute_receive {:mdns, _, _}, 150

      MDNS.browse(br, "_rtsp._tcp")
      assert_receive {:mdns, :found, %{instance: "A", txt: []}}, 1000
      assert [%{port: 554}] = MDNS.services(br, "_rtsp._tcp")

      # goodbye goes to the responder's multicast dest; point it at the browser
      {:ok, resp2} = MDNS.start_link(port: 0, dest: {{127, 0, 0, 1}, MDNS.port(br)})

      MDNS.register(resp2, %{
        instance: "B",
        type: "_rtsp._tcp",
        host: "b",
        port: 555,
        ip: {10, 0, 0, 2}
      })

      assert_receive {:mdns, :found, %{instance: "B"}}, 1000
      MDNS.unregister(resp2, "B")
      assert_receive {:mdns, :lost, %{instance: "B"}}, 1000
      assert Enum.map(MDNS.services(br, "_rtsp._tcp"), & &1.instance) == ["A"]
      assert {:error, :unknown} = MDNS.unregister(resp2, "B")
    end

    test "service type enumeration and host lookup" do
      {:ok, resp} = MDNS.start_link(port: 0)

      MDNS.register(resp, %{
        instance: "A",
        type: "_rtsp._tcp",
        host: "a",
        port: 554,
        ip: {10, 0, 0, 1}
      })

      {:ok, sock} = :gen_udp.open(0, [:binary, active: false])

      ask = fn name, type ->
        q = DNS.encode(%DNS.Message{questions: [DNS.question(name, type)]})
        :gen_udp.send(sock, {127, 0, 0, 1}, MDNS.port(resp), q)
        {:ok, {_, _, data}} = :gen_udp.recv(sock, 0, 1000)
        {:ok, m} = DNS.decode(data)
        m
      end

      assert %{answers: [%{data: "_rtsp._tcp.local"}]} =
               ask.("_services._dns-sd._udp.local", :ptr)

      assert %{answers: [%{data: {10, 0, 0, 1}}]} = ask.("A.local", :a)

      assert %{answers: [%{data: {0, 0, 554, "a.local"}}], additional: [%{type: :a}]} =
               ask.("a._rtsp._tcp.local", :srv)
    end

    @tag :multicast
    test "real multicast group" do
      join = {{224, 0, 0, 251}, {127, 0, 0, 1}}
      {:ok, a} = MDNS.start_link(join: join)
      {:ok, b} = MDNS.start_link(join: join)

      MDNS.register(a, %{
        instance: "M",
        type: "_rtsp._tcp",
        host: "m",
        port: 554,
        ip: {127, 0, 0, 1}
      })

      MDNS.subscribe(b)
      MDNS.browse(b, "_rtsp._tcp")
      assert_receive {:mdns, :found, _}, 2000
    end
  end

  describe "RTSP" do
    test "codec" do
      res = %{
        status: 200,
        reason: "OK",
        headers: [{"cseq", "3"}, {"content-type", "application/sdp"}],
        body: @sdp
      }

      bin = RTSP.encode(res)

      assert bin =~
               "RTSP/1.0 200 OK\r\nCSeq: 3\r\nContent-Type: application/sdp\r\nContent-Length: #{byte_size(@sdp)}\r\n\r\nv=0"

      assert {:ok, parsed, ""} = RTSP.parse(bin)
      assert parsed == %{res | headers: res.headers ++ [{"content-length", "#{byte_size(@sdp)}"}]}

      # partial body, pipelined messages
      assert :more = RTSP.parse(binary_part(bin, 0, byte_size(bin) - 3))
      req = %{method: "OPTIONS", uri: "*", headers: [{"cseq", "1"}], body: ""}
      assert {:ok, %{method: "OPTIONS"}, rest} = RTSP.parse(RTSP.encode(req) <> bin)
      assert {:ok, %{status: 200}, ""} = RTSP.parse(rest)
      assert {:error, :malformed} = RTSP.parse("NONSENSE\r\n\r\n")
      assert {:error, :malformed} = RTSP.parse("RTSP/1.0 abc X\r\n\r\n")
    end

    test "server DESCRIBE with client" do
      {:ok, s} = RTSP.Server.start_link(port: 0, ip: {127, 0, 0, 1})
      RTSP.Server.put_session(s, "/by-name/Stage Box", @sdp)
      port = RTSP.Server.port(s)
      base = "rtsp://127.0.0.1:#{port}"

      assert {:ok, @sdp} = RTSP.Client.describe(base <> "/by-name/Stage%20Box")
      assert {:error, {:status, 404}} = RTSP.Client.describe(base <> "/nope")
      RTSP.Server.delete_session(s, "/by-name/Stage Box")
      assert {:error, {:status, 404}} = RTSP.Client.describe(base <> "/by-name/Stage%20Box")
    end

    test "server raw: OPTIONS, unsupported method, pipelining, garbage" do
      {:ok, s} = RTSP.Server.start_link(port: 0, ip: {127, 0, 0, 1})
      RTSP.Server.put_session(s, "/x", @sdp)

      {:ok, sock} =
        :gen_tcp.connect({127, 0, 0, 1}, RTSP.Server.port(s), [:binary, active: false])

      reqs =
        for {m, u, n} <- [
              {"OPTIONS", "*", "1"},
              {"SETUP", "rtsp://h/x", "2"},
              {"DESCRIBE", "rtsp://h/x", "3"}
            ] do
          RTSP.encode(%{method: m, uri: u, headers: [{"cseq", n}], body: ""})
        end

      :ok = :gen_tcp.send(sock, Enum.join(reqs))
      buf = recv_all(sock, "", 3)
      assert {:ok, %{status: 200, headers: h1}, rest} = RTSP.parse(buf)
      assert {"public", "OPTIONS, DESCRIBE"} in h1
      assert {:ok, %{status: 501} = r2, rest} = RTSP.parse(rest)
      assert RTSP.header(r2, "cseq") == "2"
      assert {:ok, %{status: 200, body: @sdp} = r3, ""} = RTSP.parse(rest)
      assert RTSP.header(r3, "content-type") == "application/sdp"

      :gen_tcp.send(sock, "GARBAGE\r\n\r\n")
      assert {:ok, %{status: 400}, _} = RTSP.parse(recv_all(sock, "", 1))
    end

    defp recv_all(sock, buf, n) do
      count = fn b ->
        Stream.unfold(b, fn x ->
          case RTSP.parse(x) do
            {:ok, _, r} -> {1, r}
            _ -> nil
          end
        end)
        |> Enum.count()
      end

      if count.(buf) >= n do
        buf
      else
        {:ok, d} = :gen_tcp.recv(sock, 0, 1000)
        recv_all(sock, buf <> d, n)
      end
    end

    test "client errors" do
      assert {:error, _} = RTSP.Client.describe("rtsp://127.0.0.1:1/x", timeout: 200)
    end
  end

  test "NMOS is a stub" do
    assert {:error, :not_implemented} = ExAes67.NMOS.start_link()
  end
end
