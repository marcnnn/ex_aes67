defmodule ExAes67.RTSP do
  @moduledoc """
  RTSP (RFC 2326) message codec, enough for RAVENNA SDP retrieval.

  Requests are `%{method, uri, headers, body}`, responses `%{status, reason,
  headers, body}`. Headers are `{lowercase_name, value}` lists. `parse/1`
  works on a stream buffer and returns `:more` until a complete message with
  its `Content-Length` body is present.

      iex> req = %{method: "DESCRIBE", uri: "rtsp://10.0.0.5/by-name/Stage", headers: [{"cseq", "1"}], body: ""}
      iex> {:ok, ^req, ""} = ExAes67.RTSP.parse(ExAes67.RTSP.encode(req))
      iex> ExAes67.RTSP.parse("DESCRIBE rtsp://x/ RTSP/1.0\\r\\nCSeq: 1\\r\\n")
      :more
  """

  @spec encode(map()) :: binary()
  def encode(%{method: m, uri: u} = req), do: build("#{m} #{u} RTSP/1.0", req)
  def encode(%{status: s} = res), do: build("RTSP/1.0 #{s} #{res[:reason] || reason(s)}", res)

  defp build(start, msg) do
    body = Map.get(msg, :body, "")

    headers =
      msg.headers
      |> List.keydelete("content-length", 0)
      |> Kernel.++(
        if body == "", do: [], else: [{"content-length", Integer.to_string(byte_size(body))}]
      )

    start <>
      "\r\n" <>
      Enum.map_join(headers, &"#{cap(elem(&1, 0))}: #{elem(&1, 1)}\r\n") <> "\r\n" <> body
  end

  defp cap("cseq"), do: "CSeq"
  defp cap(n), do: n |> String.split("-") |> Enum.map_join("-", &String.capitalize/1)

  @doc "Parses one message from the front of `buf`: `{:ok, msg, rest} | :more | {:error, reason}`."
  def parse(buf) do
    case :binary.split(buf, "\r\n\r\n") do
      [_] ->
        :more

      [head, rest] ->
        [start | lines] = String.split(head, "\r\n")
        headers = Enum.flat_map(lines, &header/1)

        len =
          headers |> List.keyfind("content-length", 0, {nil, "0"}) |> elem(1) |> Integer.parse()

        with {n, _} <- len,
             {:ok, msg} <- start_line(start, headers) do
          case rest do
            <<body::binary-size(n), rest::binary>> -> {:ok, Map.put(msg, :body, body), rest}
            _ -> :more
          end
        else
          _ -> {:error, :malformed}
        end
    end
  end

  defp header(line) do
    case String.split(line, ":", parts: 2) do
      [n, v] -> [{String.downcase(String.trim(n)), String.trim(v)}]
      _ -> []
    end
  end

  defp start_line("RTSP/" <> _ = line, headers) do
    case String.split(line, " ", parts: 3) do
      [_, s, r] ->
        with {st, ""} <- Integer.parse(s), do: {:ok, %{status: st, reason: r, headers: headers}}

      [_, s] ->
        with {st, ""} <- Integer.parse(s),
             do: {:ok, %{status: st, reason: reason(st), headers: headers}}

      _ ->
        :error
    end
  end

  defp start_line(line, headers) do
    case String.split(line, " ") do
      [m, u, "RTSP/" <> _] -> {:ok, %{method: m, uri: u, headers: headers}}
      _ -> :error
    end
  end

  def header(msg, name), do: msg.headers |> List.keyfind(name, 0) |> then(&(&1 && elem(&1, 1)))

  def reason(200), do: "OK"
  def reason(400), do: "Bad Request"
  def reason(404), do: "Not Found"
  def reason(405), do: "Method Not Allowed"
  def reason(501), do: "Not Implemented"
  def reason(_), do: "Status"
end
