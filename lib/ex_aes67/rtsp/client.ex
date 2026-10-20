defmodule ExAes67.RTSP.Client do
  @moduledoc """
  One-shot RTSP DESCRIBE client (`rtsp://host[:port]/path`, default port 554).

      {:ok, sdp_text} = ExAes67.RTSP.Client.describe("rtsp://10.0.0.5/by-name/Stage")
  """
  alias ExAes67.RTSP

  @spec describe(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def describe(url, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 3_000)
    %URI{host: host, port: port} = URI.parse(url)

    with {:ok, sock} <-
           :gen_tcp.connect(
             String.to_charlist(host),
             port || 554,
             [:binary, active: false],
             timeout
           ) do
      req = %{
        method: "DESCRIBE",
        uri: url,
        headers: [{"cseq", "1"}, {"accept", "application/sdp"}, {"user-agent", "ex_aes67"}],
        body: ""
      }

      result =
        with :ok <- :gen_tcp.send(sock, RTSP.encode(req)),
             {:ok, res} <- read(sock, "", timeout) do
          case res do
            %{status: 200, body: body} -> {:ok, body}
            %{status: s} -> {:error, {:status, s}}
            _ -> {:error, :unexpected}
          end
        end

      :gen_tcp.close(sock)
      result
    end
  end

  defp read(sock, buf, timeout) do
    case RTSP.parse(buf) do
      {:ok, msg, _} ->
        {:ok, msg}

      :more ->
        with {:ok, data} <- :gen_tcp.recv(sock, 0, timeout), do: read(sock, buf <> data, timeout)

      {:error, _} = e ->
        e
    end
  end
end
