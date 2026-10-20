defmodule ExAes67.SDP do
  @moduledoc """
  SDP (RFC 8866) parser and generator with the AES67 / RAVENNA attributes.

  `parse/1` is lenient: LF or CRLF line ends, unknown line types and
  malformed optional lines are ignored, a missing `s=` is tolerated. The
  generic structure keeps attributes as `{name, value | nil}` pairs;
  `streams/1` interprets it as AES67 streams (`ExAes67.SDP.Stream`),
  merging session and media level attributes.

      iex> text = \"\"\"
      ...> v=0
      ...> o=- 1311738121 1311738121 IN IP4 192.168.1.10
      ...> s=Stage Box
      ...> c=IN IP4 239.69.1.2/32
      ...> t=0 0
      ...> m=audio 5004 RTP/AVP 98
      ...> a=rtpmap:98 L24/48000/8
      ...> a=ptime:0.250
      ...> a=ts-refclk:ptp=IEEE1588-2008:39-A7-94-FF-FE-07-CB-D0:0
      ...> a=mediaclk:direct=0
      ...> \"\"\"
      iex> {:ok, sdp} = ExAes67.SDP.parse(text)
      iex> {:ok, [s]} = ExAes67.SDP.streams(sdp)
      iex> {s.dest_ip, s.port, s.encoding, s.channels, s.ptime, s.ts_refclk.domain}
      {{239, 69, 1, 2}, 5004, :l24, 8, 0.25, 0}
      iex> ExAes67.SDP.Stream.packet_time_us(s)
      250
  """

  defmodule Media do
    @moduledoc false
    defstruct type: "audio",
              port: 0,
              count: nil,
              proto: "RTP/AVP",
              fmts: [],
              info: nil,
              connection: nil,
              attrs: []
  end

  defstruct version: 0,
            origin: nil,
            name: "",
            info: nil,
            connection: nil,
            time: [],
            attrs: [],
            other: [],
            media: []

  @type t :: %__MODULE__{}

  @doc "Parses SDP text."
  @spec parse(binary()) :: {:ok, t()} | {:error, atom()}
  def parse(text) do
    lines =
      text
      |> String.split(["\r\n", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&match?(<<_, ?=, _::binary>>, &1))

    case lines do
      ["v=0" <> _ | rest] ->
        sdp = Enum.reduce(rest, %__MODULE__{}, &line/2)
        {:ok, finish(sdp)}

      ["v=" <> _ | _] ->
        {:error, :bad_version}

      _ ->
        {:error, :no_version}
    end
  end

  defp finish(sdp) do
    media = for m <- Enum.reverse(sdp.media), do: %{m | attrs: Enum.reverse(m.attrs)}

    %{
      sdp
      | attrs: Enum.reverse(sdp.attrs),
        other: Enum.reverse(sdp.other),
        time: Enum.reverse(sdp.time),
        media: media
    }
  end

  defp line(<<t, ?=, v::binary>>, sdp), do: line(t, String.trim(v), sdp)

  defp line(?o, v, sdp) do
    case String.split(v) do
      [u, id, ver, nt, at, addr] ->
        %{
          sdp
          | origin: %{
              username: u,
              sess_id: id,
              sess_version: ver,
              nettype: nt,
              addrtype: at,
              address: addr
            }
        }

      _ ->
        sdp
    end
  end

  defp line(?s, v, sdp), do: %{sdp | name: v}
  defp line(?i, v, sdp), do: cur(sdp, &%{&1 | info: v}, &%{&1 | info: v})
  defp line(?t, v, sdp), do: %{sdp | time: [v | sdp.time]}

  defp line(?c, v, sdp) do
    case parse_connection(v) do
      nil -> sdp
      c -> cur(sdp, &%{&1 | connection: c}, &%{&1 | connection: c})
    end
  end

  defp line(?a, v, sdp) do
    attr =
      case String.split(v, ":", parts: 2) do
        [n, val] -> {String.downcase(n), String.trim(val)}
        [n] -> {String.downcase(n), nil}
      end

    cur(sdp, &%{&1 | attrs: [attr | &1.attrs]}, &%{&1 | attrs: [attr | &1.attrs]})
  end

  defp line(?m, v, sdp) do
    case String.split(v) do
      [type, port, proto | fmts] ->
        {port, count} =
          case String.split(port, "/") do
            [p] -> {to_int(p), nil}
            [p, n | _] -> {to_int(p), to_int(n)}
          end

        %{
          sdp
          | media: [
              %Media{type: type, port: port, count: count, proto: proto, fmts: fmts} | sdp.media
            ]
        }

      _ ->
        sdp
    end
  end

  defp line(t, v, sdp) when t in [?u, ?e, ?p, ?b], do: %{sdp | other: [{<<t>>, v} | sdp.other]}
  defp line(_, _, sdp), do: sdp

  defp cur(%{media: []} = sdp, f, _), do: f.(sdp)
  defp cur(%{media: [m | rest]} = sdp, _, g), do: %{sdp | media: [g.(m) | rest]}

  defp to_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_connection(v) do
    case String.split(v) do
      [nt, at, addr] ->
        parts = String.split(addr, "/")

        {address, ttl, count} =
          case {at, parts} do
            {"IP4", [a]} -> {a, nil, nil}
            {"IP4", [a, t]} -> {a, to_int(t), nil}
            {"IP4", [a, t, c | _]} -> {a, to_int(t), to_int(c)}
            {_, [a]} -> {a, nil, nil}
            {_, [a, c | _]} -> {a, nil, to_int(c)}
          end

        %{nettype: nt, addrtype: at, address: address, ttl: ttl, count: count}

      _ ->
        nil
    end
  end

  @doc "Serialises with CRLF line ends."
  @spec to_string(t()) :: binary()
  def to_string(%__MODULE__{} = s) do
    {pre, post} = Enum.split_with(s.other, fn {t, _} -> t != "b" end)

    ([
       "v=#{s.version}",
       s.origin && origin_line(s.origin),
       "s=#{if s.name == "", do: "-", else: s.name}",
       s.info && "i=#{s.info}"
     ] ++
       for({t, v} <- pre, do: "#{t}=#{v}") ++
       [s.connection && "c=" <> connection_text(s.connection)] ++
       for({t, v} <- post, do: "#{t}=#{v}") ++
       for(t <- s.time, do: "t=#{t}") ++
       Enum.map(s.attrs, &attr_line/1) ++
       Enum.flat_map(s.media, &media_lines/1))
    |> Enum.filter(& &1)
    |> Enum.map_join(&(&1 <> "\r\n"))
  end

  defp origin_line(o),
    do: "o=#{o.username} #{o.sess_id} #{o.sess_version} #{o.nettype} #{o.addrtype} #{o.address}"

  defp media_lines(m) do
    port = if m.count, do: "#{m.port}/#{m.count}", else: "#{m.port}"

    [
      "m=#{m.type} #{port} #{m.proto} #{Enum.join(m.fmts, " ")}",
      m.info && "i=#{m.info}",
      m.connection && "c=" <> connection_text(m.connection)
    ] ++ Enum.map(m.attrs, &attr_line/1)
  end

  defp connection_text(c) do
    addr =
      case {c.addrtype, c.ttl, c.count} do
        {_, nil, nil} -> c.address
        {"IP4", t, nil} -> "#{c.address}/#{t}"
        {"IP4", t, n} -> "#{c.address}/#{t || 1}/#{n}"
        {_, _, n} -> "#{c.address}/#{n}"
      end

    "#{c.nettype} #{c.addrtype} #{addr}"
  end

  defp attr_line({n, nil}), do: "a=#{n}"
  defp attr_line({n, v}), do: "a=#{n}:#{v}"

  @doc "First value of attribute `name` in an attribute list (`true` for flags)."
  def attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      nil -> nil
      {_, nil} -> true
      {_, v} -> v
    end
  end

  @doc "All values of attribute `name`."
  def attrs(attrs, name), do: for({^name, v} <- attrs, do: v)

  @doc """
  Interprets the audio media sections as AES67 streams. Sections that do
  not carry L16 or L24 are skipped.
  """
  @spec streams(t()) :: {:ok, [ExAes67.SDP.Stream.t()]} | {:error, :no_audio}
  def streams(%__MODULE__{} = sdp) do
    case Enum.flat_map(sdp.media, &List.wrap(ExAes67.SDP.Stream.from_media(sdp, &1))) do
      [] -> {:error, :no_audio}
      l -> {:ok, l}
    end
  end
end

defmodule ExAes67.SDP.Stream do
  @moduledoc """
  One AES67 audio stream as described by SDP.

  `ptime` and `maxptime` are milliseconds (number), `ts_refclk` is
  `%{type: :ptp, version: "IEEE1588-2008", gmid: <<_::64>>, domain: 0}`,
  `%{type: :ptp, version: v, traceable: true}`, `%{type: :localmac, mac: s}`
  or `%{type: :other, value: s}`. `mediaclk` is `{:direct, offset | nil}`,
  `:sender` or `{:other, s}`. `clock_domain` and `sync_time` carry the RAVENNA
  attributes `a=clock-domain:PTPv2 <domain>` and `a=sync-time:<n>`.

      iex> alias ExAes67.SDP.Stream
      iex> s = %Stream{name: "Out 1-2", origin_addr: "10.0.0.5", dest_ip: {239, 69, 0, 1},
      ...>   port: 5004, pt: 97, encoding: :l24, channels: 2, ptime: 1,
      ...>   ts_refclk: Stream.ptp_refclk(<<0x39, 0xA7, 0x94, 0xFF, 0xFE, 7, 0xCB, 0xD0>>, 0),
      ...>   mediaclk: {:direct, 0}, direction: :sendonly}
      iex> {:ok, sdp} = ExAes67.SDP.parse(Stream.generate(s))
      iex> {:ok, [back]} = ExAes67.SDP.streams(sdp)
      iex> back.ts_refclk.gmid == s.ts_refclk.gmid and back.channels == 2 and back.direction == :sendonly
      true
  """
  alias ExAes67.SDP
  alias ExAes67.SDP.Media

  defstruct name: "",
            info: nil,
            sess_id: "0",
            sess_version: "0",
            origin_addr: "0.0.0.0",
            dest_ip: nil,
            ttl: 32,
            port: 5004,
            pt: 97,
            encoding: :l24,
            rate: 48_000,
            channels: 2,
            ptime: nil,
            maxptime: nil,
            framecount: nil,
            ts_refclk: nil,
            mediaclk: nil,
            clock_domain: nil,
            sync_time: nil,
            direction: :sendrecv,
            source_filter: nil

  @type t :: %__MODULE__{}

  @doc "PTP reference clock descriptor."
  def ptp_refclk(gmid, domain, version \\ "IEEE1588-2008"),
    do: %{type: :ptp, version: version, gmid: gmid, domain: domain}

  @doc "Packet time in microseconds (from `ptime`, else `framecount`, else 1000)."
  def packet_time_us(%__MODULE__{ptime: p}) when is_number(p), do: round(p * 1000)

  def packet_time_us(%__MODULE__{framecount: n, rate: r}) when is_integer(n),
    do: round(n * 1_000_000 / r)

  def packet_time_us(_), do: 1000

  @doc false
  def from_media(%SDP{} = sdp, %Media{type: "audio"} = m) do
    attrs = m.attrs

    all = fn name ->
      case SDP.attr(attrs, name) || SDP.attr(sdp.attrs, name) do
        v when is_binary(v) -> v
        _ -> nil
      end
    end

    with {pt, enc, rate, ch} <- find_rtpmap(m),
         %{address: addr} = conn <- m.connection || sdp.connection do
      %__MODULE__{
        name: sdp.name,
        info: m.info || sdp.info,
        sess_id: sdp.origin && sdp.origin.sess_id,
        sess_version: sdp.origin && sdp.origin.sess_version,
        origin_addr: sdp.origin && sdp.origin.address,
        dest_ip: ip(addr),
        ttl: conn.ttl,
        port: m.port,
        pt: pt,
        encoding: enc,
        rate: rate,
        channels: ch,
        ptime: num(all.("ptime")),
        maxptime: num(all.("maxptime")),
        framecount: int(all.("framecount")),
        ts_refclk: refclk(all.("ts-refclk")),
        mediaclk: mediaclk(all.("mediaclk")),
        clock_domain: clock_domain(all.("clock-domain")),
        sync_time: int(all.("sync-time")),
        direction: direction(attrs) || direction(sdp.attrs) || :sendrecv,
        source_filter: source_filter(all.("source-filter"))
      }
    else
      _ -> nil
    end
  end

  def from_media(_, _), do: nil

  defp find_rtpmap(m) do
    Enum.find_value(SDP.attrs(m.attrs, "rtpmap"), fn v ->
      with [pt, enc] <- String.split(v, ~r/\s+/, parts: 2),
           [name, rate | rest] <- String.split(enc, "/"),
           {pt, ""} <- Integer.parse(pt),
           e when e in [:l16, :l24] <- encoding(name),
           {rate, _} <- Integer.parse(rate) do
        ch =
          case rest do
            [c | _] -> with {n, _} <- Integer.parse(c), do: n
            [] -> 1
          end

        {pt, e, rate, if(is_integer(ch), do: ch, else: 1)}
      else
        _ -> nil
      end
    end)
  end

  defp encoding(name) do
    case String.downcase(name) do
      "l16" -> :l16
      "l24" -> :l24
      _ -> nil
    end
  end

  defp ip(addr) do
    case :inet.parse_address(String.to_charlist(addr)) do
      {:ok, t} -> t
      _ -> addr
    end
  end

  defp num(nil), do: nil

  defp num(v) do
    case Float.parse(if(String.starts_with?(v, "."), do: "0" <> v, else: v)) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp int(nil), do: nil

  defp int(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp direction(attrs) do
    attrs
    |> Enum.reverse()
    |> Enum.find_value(fn
      {"sendrecv", _} -> :sendrecv
      {"sendonly", _} -> :sendonly
      {"recvonly", _} -> :recvonly
      {"inactive", _} -> :inactive
      _ -> nil
    end)
  end

  @gmid ~r/^ptp=([^:]+):([0-9A-Fa-f]{2}(?:[-:][0-9A-Fa-f]{2}){7})(?::(\d+))?$/

  defp refclk(nil), do: nil

  defp refclk(v) do
    cond do
      m = Regex.run(@gmid, v) ->
        [_, ver, gmid, dom] = m ++ if(length(m) == 3, do: ["0"], else: [])

        gmid =
          for h <- String.split(gmid, ["-", ":"]), into: <<>>, do: <<String.to_integer(h, 16)>>

        ptp_refclk(gmid, int(dom) || 0, ver)

      m = Regex.run(~r/^ptp=([^:]+):traceable$/, v) ->
        %{type: :ptp, version: Enum.at(m, 1), traceable: true}

      String.starts_with?(v, "localmac=") ->
        %{type: :localmac, mac: String.replace_prefix(v, "localmac=", "")}

      true ->
        %{type: :other, value: v}
    end
  end

  defp refclk_text(%{type: :ptp, traceable: true, version: ver}), do: "ptp=#{ver}:traceable"

  defp refclk_text(%{type: :ptp, gmid: g, domain: d, version: ver}) do
    id =
      g
      |> :binary.bin_to_list()
      |> Enum.map_join("-", &(Integer.to_string(&1, 16) |> String.pad_leading(2, "0")))

    "ptp=#{ver}:#{id}:#{d}"
  end

  defp refclk_text(%{type: :localmac, mac: m}), do: "localmac=#{m}"
  defp refclk_text(%{type: :other, value: v}), do: v

  defp mediaclk(nil), do: nil
  defp mediaclk("sender" <> _), do: :sender

  defp mediaclk("direct" <> rest) do
    case Regex.run(~r/^=(\d+)/, rest) do
      [_, n] -> {:direct, String.to_integer(n)}
      _ -> {:direct, nil}
    end
  end

  defp mediaclk(v), do: {:other, v}

  defp mediaclk_text({:direct, nil}), do: "direct"
  defp mediaclk_text({:direct, n}), do: "direct=#{n}"
  defp mediaclk_text(:sender), do: "sender"
  defp mediaclk_text({:other, v}), do: v

  defp clock_domain(nil), do: nil

  defp clock_domain(v) do
    case String.split(v) do
      [kind, d] -> {kind, int(d) || 0}
      [kind] -> {kind, 0}
      _ -> nil
    end
  end

  defp source_filter(nil), do: nil

  defp source_filter(v) do
    case String.split(v) do
      [mode, _nt, _at, dest | srcs] when mode in ["incl", "excl"] ->
        %{mode: String.to_atom(mode), dest: ip(dest), sources: Enum.map(srcs, &ip/1)}

      _ ->
        nil
    end
  end

  defp ip_text(t) when is_tuple(t), do: t |> :inet.ntoa() |> List.to_string()
  defp ip_text(s), do: s

  defp fmt_num(n) when is_integer(n), do: Integer.to_string(n)

  defp fmt_num(f) do
    f
    |> :erlang.float_to_binary(decimals: 6)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  @doc """
  Builds the generic SDP for a stream. `a=clock-domain` and `a=sync-time`
  are emitted when the struct carries them.
  """
  @spec to_sdp(t()) :: SDP.t()
  def to_sdp(%__MODULE__{} = s) do
    ver = if(s.dest_ip && tuple_size(s.dest_ip) == 8, do: "IP6", else: "IP4")
    ttl = if ver == "IP4" and multicast?(s.dest_ip), do: s.ttl || 32

    attrs =
      [
        s.direction != :sendrecv && {Atom.to_string(s.direction), nil},
        s.clock_domain &&
          {"clock-domain", "#{elem(s.clock_domain, 0)} #{elem(s.clock_domain, 1)}"},
        {"rtpmap",
         "#{s.pt} #{s.encoding |> Atom.to_string() |> String.upcase()}/#{s.rate}/#{s.channels}"},
        s.ptime && {"ptime", fmt_num(s.ptime)},
        s.maxptime && {"maxptime", fmt_num(s.maxptime)},
        s.framecount && {"framecount", Integer.to_string(s.framecount)},
        s.sync_time && {"sync-time", Integer.to_string(s.sync_time)},
        s.mediaclk && {"mediaclk", mediaclk_text(s.mediaclk)},
        s.ts_refclk && {"ts-refclk", refclk_text(s.ts_refclk)},
        s.source_filter && {"source-filter", sf_text(s.source_filter, ver)}
      ]
      |> Enum.filter(& &1)

    %SDP{
      origin: %{
        username: "-",
        sess_id: s.sess_id || "0",
        sess_version: s.sess_version || "0",
        nettype: "IN",
        addrtype: "IP4",
        address: s.origin_addr || "0.0.0.0"
      },
      name: s.name,
      connection: %{
        nettype: "IN",
        addrtype: ver,
        address: ip_text(s.dest_ip),
        ttl: ttl,
        count: nil
      },
      time: ["0 0"],
      media: [
        %Media{
          type: "audio",
          port: s.port,
          proto: "RTP/AVP",
          fmts: [Integer.to_string(s.pt)],
          info: s.info,
          attrs: attrs
        }
      ]
    }
  end

  @doc "SDP text for a stream."
  @spec generate(t()) :: binary()
  def generate(%__MODULE__{} = s), do: s |> to_sdp() |> SDP.to_string()

  defp multicast?({a, _, _, _}), do: a in 224..239
  defp multicast?(_), do: false

  defp sf_text(%{mode: m, dest: d, sources: srcs}, ver),
    do: Enum.join([m, "IN", ver, ip_text(d) | Enum.map(srcs, &ip_text/1)], " ")
end
