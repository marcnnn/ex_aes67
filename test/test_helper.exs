# :verilator - co-simulation, needs verilator in PATH
# :interop - real implementations in podman containers, `mix test --only interop`
# :multicast - needs a multicast capable interface, run with --include multicast
exclude =
  [multicast: true, interop: true] ++
    if(System.find_executable("verilator"), do: [], else: [verilator: true])

Code.require_file("interop/support/interop.ex", __DIR__)
Code.require_file("interop/support/aes67_interop.ex", __DIR__)
ExUnit.start(exclude: exclude)
