defmodule ExAes67.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_aes67,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: [licenses: ["Apache-2.0"]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # SIBLINGS_DIR points the path deps at another checkout of the siblings,
  # e.g. a snapshot of their last commits while they are being edited.
  @siblings System.get_env("SIBLINGS_DIR", "..")

  defp deps do
    [
      {:ex_hdl, path: Path.join(@siblings, "exhdl")},
      {:ex_net, path: Path.join(@siblings, "ex_net")},
      {:ex_ptp, path: Path.join(@siblings, "ex_ptp")},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end
end
