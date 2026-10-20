defmodule ExAes67.DNS do
  @moduledoc """
  DNS message codec for mDNS / DNS-SD (RFC 1035, 6762, 6763).

  Names are dotted strings without trailing dot (`"x._rtsp._tcp.local"`);
  labels containing dots are not supported. Decoding follows compression
  pointers, encoding compresses repeated suffixes.

  A record is `%{name, type, class, cache_flush, ttl, data}` with `type`
  `:a | :aaaa | :ptr | :txt | :srv | integer`. Data is an IP tuple, a name,
  a list of binaries (TXT), `{priority, weight, port, target}` (SRV) or a raw
  binary. A question is `%{name, type, class, unicast}` (`unicast` is the QU
  bit).

      iex> alias ExAes67.DNS
      iex> q = DNS.question("_rtsp._tcp.local", :ptr)
      iex> msg = %DNS.Message{questions: [q]}
      iex> {:ok, ^msg} = DNS.decode(DNS.encode(msg))
      iex> rr = DNS.record("a.local", :a, {10, 0, 0, 1}, 120)
      iex> {:ok, %{answers: [^rr]}} = DNS.decode(DNS.encode(%DNS.Message{response: true, answers: [rr]}))
  """

  defmodule Message do
    @moduledoc false
    defstruct id: 0,
              response: false,
              authoritative: false,
              truncated: false,
              opcode: 0,
              rcode: 0,
              questions: [],
              answers: [],
              authority: [],
              additional: []
  end

  @types %{a: 1, ns: 2, cname: 5, ptr: 12, txt: 16, aaaa: 28, srv: 33, any: 255}
  @type_ids Map.new(@types, fn {k, v} -> {v, k} end)

  def question(name, type, opts \\ []),
    do: %{name: name, type: type, class: 1, unicast: Keyword.get(opts, :unicast, false)}

  def record(name, type, data, ttl, opts \\ []),
    do: %{
      name: name,
      type: type,
      class: 1,
      cache_flush: Keyword.get(opts, :cache_flush, false),
      ttl: ttl,
      data: data
    }

  @spec encode(%Message{}) :: binary()
  def encode(%Message{} = m) do
    flags =
      <<b(m.response)::1, m.opcode::4, b(m.authoritative)::1, b(m.truncated)::1, 0::1, 0::1, 0::3,
        m.rcode::4>>

    head =
      <<m.id::16, flags::binary, length(m.questions)::16, length(m.answers)::16,
        length(m.authority)::16, length(m.additional)::16>>

    {body, _} =
      Enum.reduce(
        Enum.map(m.questions, &{:q, &1}) ++
          Enum.map(m.answers ++ m.authority ++ m.additional, &{:r, &1}),
        {head, %{}},
        fn
          {:q, q}, {acc, ptrs} ->
            {n, ptrs} = enc_name(q.name, byte_size(acc), ptrs)

            {<<acc::binary, n::binary, type_id(q.type)::16, b(q[:unicast])::1, q.class::15>>,
             ptrs}

          {:r, r}, {acc, ptrs} ->
            {n, ptrs} = enc_name(r.name, byte_size(acc), ptrs)
            fixed = <<type_id(r.type)::16, b(r[:cache_flush])::1, r.class::15, r.ttl::32>>
            off = byte_size(acc) + byte_size(n) + byte_size(fixed) + 2
            {data, ptrs} = enc_data(r.type, r.data, off, ptrs)
            {<<acc::binary, n::binary, fixed::binary, byte_size(data)::16, data::binary>>, ptrs}
        end
      )

    body
  end

  defp b(true), do: 1
  defp b(_), do: 0

  defp type_id(t) when is_integer(t), do: t
  defp type_id(t), do: Map.fetch!(@types, t)

  defp enc_name("", _, ptrs), do: {<<0>>, ptrs}

  defp enc_name(name, off, ptrs) do
    labels = String.split(name, ".")
    enc_labels(labels, off, ptrs, <<>>)
  end

  defp enc_labels([], _, ptrs, acc), do: {acc <> <<0>>, ptrs}

  defp enc_labels([l | rest] = labels, off, ptrs, acc) do
    suffix = Enum.join(labels, ".") |> String.downcase()

    case ptrs do
      %{^suffix => p} ->
        {<<acc::binary, 3::2, p::14>>, ptrs}

      _ ->
        ptrs =
          if off + byte_size(acc) < 0x4000,
            do: Map.put(ptrs, suffix, off + byte_size(acc)),
            else: ptrs

        enc_labels(rest, off, ptrs, <<acc::binary, byte_size(l), l::binary>>)
    end
  end

  defp enc_data(:a, {a, b, c, d}, _, p), do: {<<a, b, c, d>>, p}
  defp enc_data(:aaaa, t, _, p), do: {for(x <- Tuple.to_list(t), into: <<>>, do: <<x::16>>), p}
  defp enc_data(t, name, off, p) when t in [:ptr, :ns, :cname], do: enc_name(name, off, p)
  defp enc_data(:txt, [], _, p), do: {<<0>>, p}

  defp enc_data(:txt, strs, _, p),
    do: {for(s <- strs, into: <<>>, do: <<byte_size(s), s::binary>>), p}

  defp enc_data(:srv, {prio, w, port, target}, off, p) do
    {n, p} = enc_name(target, off + 6, p)
    {<<prio::16, w::16, port::16, n::binary>>, p}
  end

  defp enc_data(_, raw, _, p) when is_binary(raw), do: {raw, p}

  @spec decode(binary()) :: {:ok, %Message{}} | {:error, atom()}
  def decode(
        <<id::16, qr::1, op::4, aa::1, tc::1, _rd::1, _ra::1, _z::3, rc::4, qd::16, an::16,
          ns::16, ar::16, _::binary>> = msg
      ) do
    pos = 12

    with {:ok, qs, pos} <- many(msg, pos, qd, &question_at/2),
         {:ok, ans, pos} <- many(msg, pos, an, &record_at/2),
         {:ok, auth, pos} <- many(msg, pos, ns, &record_at/2),
         {:ok, add, _} <- many(msg, pos, ar, &record_at/2) do
      {:ok,
       %Message{
         id: id,
         response: qr == 1,
         opcode: op,
         authoritative: aa == 1,
         truncated: tc == 1,
         rcode: rc,
         questions: qs,
         answers: ans,
         authority: auth,
         additional: add
       }}
    end
  catch
    :bad -> {:error, :malformed}
  end

  def decode(_), do: {:error, :truncated}

  defp many(msg, pos, n, f), do: many(msg, pos, n, f, [])
  defp many(_, pos, 0, _, acc), do: {:ok, Enum.reverse(acc), pos}

  defp many(msg, pos, n, f, acc) do
    {item, pos} = f.(msg, pos)
    many(msg, pos, n - 1, f, [item | acc])
  end

  defp question_at(msg, pos) do
    {name, pos} = name_at(msg, pos, 0)

    case msg do
      <<_::binary-size(pos), t::16, u::1, c::15, _::binary>> ->
        {%{name: name, type: Map.get(@type_ids, t, t), class: c, unicast: u == 1}, pos + 4}

      _ ->
        throw(:bad)
    end
  end

  defp record_at(msg, pos) do
    {name, pos} = name_at(msg, pos, 0)

    case msg do
      <<_::binary-size(pos), t::16, cf::1, c::15, ttl::32, len::16, data::binary-size(len),
        _::binary>> ->
        type = Map.get(@type_ids, t, t)

        rec = %{
          name: name,
          type: type,
          class: c,
          cache_flush: cf == 1,
          ttl: ttl,
          data: data_at(msg, type, data, pos + 10)
        }

        {rec, pos + 10 + len}

      _ ->
        throw(:bad)
    end
  end

  defp data_at(_, :a, <<a, b, c, d>>, _), do: {a, b, c, d}
  defp data_at(_, :aaaa, <<d::binary-size(16)>>, _), do: List.to_tuple(for <<x::16 <- d>>, do: x)
  defp data_at(msg, t, _, off) when t in [:ptr, :ns, :cname], do: name_at(msg, off, 0) |> elem(0)
  defp data_at(_, :txt, d, _), do: if(txt(d, []) == [""], do: [], else: txt(d, []))

  defp data_at(msg, :srv, <<prio::16, w::16, port::16, _::binary>>, off),
    do: {prio, w, port, name_at(msg, off + 6, 0) |> elem(0)}

  defp data_at(_, _, d, _), do: d

  defp txt(<<>>, acc), do: Enum.reverse(acc)
  defp txt(<<l, s::binary-size(l), rest::binary>>, acc), do: txt(rest, [s | acc])
  defp txt(_, _), do: throw(:bad)

  # returns {dotted name, position after the name in the original stream}
  defp name_at(_, _, depth) when depth > 16, do: throw(:bad)

  defp name_at(msg, pos, depth) do
    case msg do
      <<_::binary-size(pos), 0, _::binary>> ->
        {"", pos + 1}

      <<_::binary-size(pos), 3::2, p::14, _::binary>> ->
        {n, _} = name_at(msg, p, depth + 1)
        {n, pos + 2}

      <<_::binary-size(pos), l, label::binary-size(l), _::binary>> when l < 64 ->
        {rest, after_pos} = name_at(msg, pos + 1 + l, depth)
        {if(rest == "", do: label, else: label <> "." <> rest), after_pos}

      _ ->
        throw(:bad)
    end
  end
end
