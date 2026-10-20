defmodule ExAes67.NMOS do
  @moduledoc """
  NMOS IS-04 (discovery and registration) and IS-05 (connection management)
  placeholder. Not implemented: both are HTTP/JSON APIs and need an HTTP
  server and a JSON codec (for example `bandit` or `plug_cowboy` plus
  `jason`) which this library does not depend on yet. See the README for
  the plan.
  """

  @doc "Always `{:error, :not_implemented}`."
  @spec start_link(keyword()) :: {:error, :not_implemented}
  def start_link(_opts \\ []), do: {:error, :not_implemented}
end
