defmodule ExAes67.Test.Loop do
  @moduledoc false
  # Closed-loop driver for multi-clock `ExHdl.RTL.Sim` runs: before every edge event `fun`
  # sees the outputs (as the edge will sample them) and chooses the inputs.
  alias ExHdl.RTL.{Module, Sim}

  @doc """
  `fun.(state, ev)` with `ev = %{i, t, fire, outs}` returns `{inputs, state}`. Inputs not
  returned keep their value. Resets are the caller's business (`rst_n`, `rst_mac_n` in the
  first events). Returns `%{events: [%{t, fire, inputs, outs}], state: state, stim: [...]}`;
  `stim` holds the full input map of every event for Verilator replays.
  """
  def run(mod, n, state, fun, opts \\ []) do
    sim = Sim.new(mod, Keyword.take(opts, [:clocks]))
    sched = mod |> Sim.schedule(n, Keyword.take(opts, [:clocks])) |> List.to_tuple()
    zeros = Map.new(Module.data_inputs(mod), &{&1.name, 0})

    {rev, state, _, _} =
      Enum.reduce(0..(n - 1), {[], state, sim, zeros}, fn i, {rows, st, sim, cur} ->
        {t, fire} = elem(sched, i)
        ev = %{i: i, t: t, fire: fire, outs: Sim.outputs(sim)}
        {inputs, st} = fun.(st, ev)
        cur = Map.merge(cur, Map.new(inputs))
        sim = Sim.poke(sim, cur)
        outs = Sim.outputs(sim)
        {[%{t: t, fire: fire, inputs: cur, outs: outs} | rows], st, Sim.step(sim), cur}
      end)

    rows = Enum.reverse(rev)
    %{events: rows, state: state, stim: Enum.map(rows, & &1.inputs)}
  end

  @doc """
  Open-loop variant for long runs in Verilator: the driver `fun` sees `oracle.(i)` (a predicted
  output map, e.g. the media clock ticks of a free-running design) instead of simulator outputs,
  the stimulus it produces is run with `ExHdl.RTL.Cosim`, and the real outputs are returned in the
  shape of `run/5`. The caller checks that the oracle was right.
  """
  def run_cosim(mod, n, state, fun, oracle, opts \\ []) do
    zeros = Map.new(Module.data_inputs(mod), &{&1.name, 0})
    sched = mod |> Sim.schedule(n, Keyword.take(opts, [:clocks])) |> List.to_tuple()

    {rev, state, _} =
      Enum.reduce(0..(n - 1), {[], state, zeros}, fn i, {rows, st, cur} ->
        {t, fire} = elem(sched, i)
        {inputs, st} = fun.(st, %{i: i, t: t, fire: fire, outs: oracle.(i)})
        cur = Map.merge(cur, Map.new(inputs))
        {[cur | rows], st, cur}
      end)

    stim = Enum.reverse(rev)

    {:ok, cosim} = ExHdl.RTL.Cosim.build(mod)
    {:ok, outs} = ExHdl.RTL.Cosim.run(cosim, stim, Keyword.take(opts, [:clocks]))

    events =
      for {{t, fire}, inputs, o} <- Enum.zip([Tuple.to_list(sched), stim, outs]),
          do: %{t: t, fire: fire, inputs: inputs, outs: o}

    %{events: events, state: state, stim: stim}
  end
end
