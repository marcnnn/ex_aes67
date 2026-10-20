defmodule ExAes67.RTLDrv do
  @moduledoc false
  # Cycle driver around ExHdl.RTL.Sim that records the stimulus, so a run can be
  # replayed in Verilator (`cosim/1`) and compared output for output.
  alias ExHdl.RTL.{Cosim, Sim}

  defstruct [:mod, :sim, stim: [], pend: %{}]

  def new(mod, init \\ %{}) do
    sim = Sim.new(mod)
    d = %__MODULE__{mod: mod, sim: sim}
    d = d |> set(%{rst_n: 0}) |> step(2) |> set(Map.put(init, :rst_n, 1))
    step(d)
  end

  def set(%__MODULE__{} = d, inputs) do
    inputs = Map.new(inputs)
    %{d | sim: Sim.poke(d.sim, inputs), pend: Map.merge(d.pend, inputs)}
  end

  def step(%__MODULE__{} = d, n \\ 1) when n >= 1 do
    d = %{d | sim: Sim.step(d.sim), stim: [d.pend | d.stim], pend: %{}}
    if n == 1, do: d, else: step(d, n - 1)
  end

  def peek(%__MODULE__{sim: sim}, name), do: Sim.peek(sim, name)
  def outputs(%__MODULE__{sim: sim}), do: Sim.outputs(sim)
  def stimulus(%__MODULE__{} = d), do: Enum.reverse([d.pend | d.stim])
  def cycles(%__MODULE__{stim: s}), do: length(s)

  @doc "Replays the recorded stimulus in Verilator, compared with the BEAM simulator."
  def cosim(%__MODULE__{} = d), do: Cosim.compare(d.mod, stimulus(d))
end
