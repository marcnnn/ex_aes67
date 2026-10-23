defmodule Interop.Aes67 do
  @moduledoc false
  # Container orchestration for the GStreamer and PipeWire tests. All containers join the
  # `ex-interop` podman network. Packet captures are taken by a tcpdump container that
  # shares the network namespace of the container under test.

  @network "ex-interop"

  def network do
    System.cmd("podman", ["network", "create", @network], stderr_to_stdout: true)
    @network
  end

  def unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  def tmp_dir do
    d = Interop.Tshark.tmp_dir()
    File.chmod!(d, 0o777)
    d
  end

  def podman(args, opts \\ []), do: System.cmd("podman", args, [stderr_to_stdout: true] ++ opts)

  def cleanup_on_exit(name),
    do: ExUnit.Callbacks.on_exit(fn -> podman(["rm", "-f", name]) end)

  @doc "Starts a detached container; `args` are `podman run` arguments after `-d --rm --name`."
  def start(name, args) do
    {out, 0} = podman(["run", "-d", "--rm", "--name", name, "--network", network()] ++ args)
    cleanup_on_exit(name)
    String.trim(out)
  end

  @doc "A container that only keeps a network namespace alive; exec into it with `exec/3`."
  def holder(image, name) do
    Interop.Podman.require_image!(image)
    start(name, [Interop.Podman.image(image), "sleep", "300"])
  end

  def exec(name, cmd, opts \\ []) do
    env = Enum.flat_map(Keyword.get(opts, :env, []), fn {k, v} -> ["-e", "#{k}=#{v}"] end)
    podman(["exec"] ++ env ++ [name | cmd])
  end

  def logs(name), do: elem(podman(["logs", name]), 0)

  @doc """
  Starts tcpdump in the network namespace of `target`, writing `dir/cap.pcap`.
  Returns a function that stops it and returns the captured frames.
  """
  def capture(target, dir, filter) do
    Interop.Podman.require_image!("nettools")
    name = unique("ex-interop-tcap")

    {_, 0} =
      podman([
        "run",
        "-d",
        "--name",
        name,
        "--network",
        "container:" <> target,
        "--cap-add=NET_RAW,NET_ADMIN",
        "-v",
        "#{dir}:/out:z",
        Interop.Podman.image("nettools"),
        "sh",
        "-c",
        "exec tcpdump -i eth0 -U -s 0 -w /out/cap.pcap '#{filter}'"
      ])

    cleanup_on_exit(name)
    # tcpdump needs a moment to open the device
    Process.sleep(1_500)

    fn ->
      podman(["kill", "-s", "INT", name])
      Process.sleep(1_000)
      podman(["rm", "-f", name])
      {_, frames} = Interop.Captures.frames(Path.join(dir, "cap.pcap"))
      frames
    end
  end

  @doc "Runs `aes67_send.exs` in the BEAM container, returns its output."
  def send_stream(args) do
    Interop.Podman.require_image!("beam")
    libs = Path.join(Mix.Project.build_path(), "lib")
    support = Path.join(__DIR__, "")
    name = unique("ex-interop-send")

    {out, status} =
      podman(
        [
          "run",
          "--rm",
          "--name",
          name,
          "--network",
          network(),
          "--security-opt",
          "label=disable",
          "-v",
          "#{libs}:/libs:ro",
          "-v",
          "#{support}:/support:ro",
          Interop.Podman.image("beam"),
          "elixir",
          "-pa",
          "/libs/*/ebin",
          "/support/aes67_send.exs"
        ] ++ Enum.map(args, fn {k, v} -> "#{k}=#{v}" end)
      )

    if status != 0, do: raise("aes67_send failed:\n#{out}")
    out
  end

  @doc "RTP packets (decoded with ExAes67.RTP) to `port` found in captured frames."
  def rtp_packets(frames, port) do
    for f <- frames,
        {:udp, ^port, pl} <- [Interop.Frame.payload(f)],
        {:ok, r} <- [ExAes67.RTP.decode(pl)],
        do: r
  end

  @doc "SAP packets of captured frames, decoded."
  def sap_packets(frames) do
    for f <- frames,
        {:udp, 9875, pl} <- [Interop.Frame.payload(f)],
        {:ok, p} <- [ExAes67.SAP.decode(pl)],
        do: p
  end

  @doc "`{seq_step, ts_step}` frequencies over consecutive packets."
  def steps(pkts) do
    pkts
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] ->
      {ExAes67.RTP.seq_diff(b.seq, a.seq), ExAes67.RTP.ts_diff(b.ts, a.ts)}
    end)
    |> Enum.frequencies()
  end

  @doc """
  Checks a 1 kHz sine at half scale, 48 kHz (period 48 samples), in a list of samples of
  one channel: amplitude within 3 %, and `x[n+48] ~ x[n]` within `tol`.
  """
  def sine_error(samples, full_scale, tol) do
    peak = samples |> Enum.map(&abs/1) |> Enum.max()
    pairs = Enum.zip(samples, Enum.drop(samples, 48))
    worst = pairs |> Enum.map(fn {a, b} -> abs(a - b) end) |> Enum.max(fn -> 0 end)
    %{peak_ratio: peak / (0.5 * full_scale), worst_period_error: worst, ok: worst <= tol}
  end
end
