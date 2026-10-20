defmodule ExAes67.RTSP.Server do
  @moduledoc """
  RTSP server answering OPTIONS and DESCRIBE with SDP, which is all RAVENNA
  and AES67 receivers need to learn a session. Other methods get 501.

  Sessions are registered by URL path (`"/by-name/Stage Box"`); a request URI
  matches on its path, percent-decoded. Options: `:port` (default 554, `0`
  for ephemeral), `:ip` (bind address, default any), `:name`.

      {:ok, s} = ExAes67.RTSP.Server.start_link(port: 0)
      ExAes67.RTSP.Server.put_session(s, "/by-name/Stage", sdp_text)
      ExAes67.RTSP.Client.describe("rtsp://127.0.0.1:\#{ExAes67.RTSP.Server.port(s)}/by-name/Stage")
  """
  use GenServer
  alias ExAes67.RTSP

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def put_session(server, path, sdp), do: GenServer.call(server, {:put, path, sdp})
  def delete_session(server, path), do: GenServer.call(server, {:delete, path})
  def port(server), do: GenServer.call(server, :port)

  @impl true
  def init(opts) do
    lopts = [
      :binary,
      active: false,
      reuseaddr: true,
      packet: :raw,
      ip: Keyword.get(opts, :ip, {0, 0, 0, 0})
    ]

    with {:ok, lsock} <- :gen_tcp.listen(Keyword.get(opts, :port, 554), lopts) do
      server = self()
      acceptor = spawn_link(fn -> accept(lsock, server) end)
      {:ok, %{lsock: lsock, sessions: %{}, acceptor: acceptor}}
    else
      {:error, r} -> {:stop, r}
    end
  end

  @impl true
  def handle_call({:put, path, sdp}, _, st), do: {:reply, :ok, put_in(st.sessions[path], sdp)}

  def handle_call({:delete, path}, _, st),
    do: {:reply, :ok, %{st | sessions: Map.delete(st.sessions, path)}}

  def handle_call(:port, _, st), do: {:reply, elem(:inet.port(st.lsock), 1), st}
  def handle_call({:lookup, path}, _, st), do: {:reply, Map.fetch(st.sessions, path), st}

  defp accept(lsock, server) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        pid =
          spawn(fn ->
            receive do
              :go -> serve(sock, server, "")
            end
          end)

        :gen_tcp.controlling_process(sock, pid)
        send(pid, :go)
        accept(lsock, server)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock, server, buf) do
    case RTSP.parse(buf) do
      {:ok, req, rest} ->
        :gen_tcp.send(sock, RTSP.encode(respond(req, server)))
        serve(sock, server, rest)

      :more ->
        case :gen_tcp.recv(sock, 0, 30_000) do
          {:ok, data} -> serve(sock, server, buf <> data)
          _ -> :gen_tcp.close(sock)
        end

      {:error, _} ->
        :gen_tcp.send(sock, RTSP.encode(%{status: 400, headers: [{"cseq", "0"}]}))
        :gen_tcp.close(sock)
    end
  end

  defp respond(%{method: "OPTIONS"} = req, _),
    do: %{status: 200, headers: base(req) ++ [{"public", "OPTIONS, DESCRIBE"}]}

  defp respond(%{method: "DESCRIBE"} = req, server) do
    path = req.uri |> URI.parse() |> Map.get(:path) |> to_string() |> URI.decode()

    case GenServer.call(server, {:lookup, path}) do
      {:ok, sdp} ->
        %{
          status: 200,
          headers: base(req) ++ [{"content-base", req.uri}, {"content-type", "application/sdp"}],
          body: sdp
        }

      :error ->
        %{status: 404, headers: base(req)}
    end
  end

  defp respond(req, _), do: %{status: 501, headers: base(req)}

  defp base(req), do: [{"cseq", RTSP.header(req, "cseq") || "0"}]
end
