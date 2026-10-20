# :verilator - co-simulation, needs verilator in PATH
# :multicast - needs a multicast capable interface, run with --include multicast
exclude =
  [multicast: true] ++ if(System.find_executable("verilator"), do: [], else: [verilator: true])

ExUnit.start(exclude: exclude)
