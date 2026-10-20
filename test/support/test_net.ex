defmodule ExAes67.TestNet do
  @moduledoc false
  # Deterministic network: per packet delay `base + uniform(0..jitter)` media
  # ticks, loss probability, duplicate probability. Reordering follows from jitter.

  def deliver(packets, opts) do
    :rand.seed(:exsss, {Keyword.get(opts, :seed, 1), 2, 3})
    base = Keyword.get(opts, :base, 0)
    jitter = Keyword.get(opts, :jitter, 0)
    loss = Keyword.get(opts, :loss, 0.0)
    dup = Keyword.get(opts, :dup, 0.0)

    packets
    |> Enum.flat_map(fn {t, p} ->
      if :rand.uniform() < loss do
        []
      else
        copies = if :rand.uniform() < dup, do: 2, else: 1
        for _ <- 1..copies, do: {t + base + :rand.uniform(jitter + 1) - 1, p}
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end
end
