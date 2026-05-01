defmodule AlpacaTrader.StrategyRegistry do
  @moduledoc """
  Loads strategies from config, starts one Runner per strategy via
  StrategySupervisor, and provides tick/1 that fans across all runners
  collecting Signals.
  """
  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @tick_timeout_ms 30_000

  def tick(registry \\ __MODULE__, ctx),
    do: GenServer.call(registry, {:tick, ctx}, @tick_timeout_ms)

  def loaded_ids(registry \\ __MODULE__), do: GenServer.call(registry, :ids)

  @impl true
  def init(opts) do
    configs = Keyword.get_lazy(opts, :strategies, fn ->
      Application.get_env(:alpaca_trader, :strategies, [])
    end)

    ids =
      Enum.reduce(configs, [], fn {mod, cfg}, acc ->
        case AlpacaTrader.StrategySupervisor.start_strategy(mod, cfg) do
          {:ok, _pid} -> [mod.id() | acc]
          {:error, {:already_started, _}} -> [mod.id() | acc]
          {:error, reason} -> raise "failed to start strategy #{mod.id()}: #{inspect(reason)}"
        end
      end)
      |> Enum.reverse()

    {:ok, ids}
  end

  @impl true
  def handle_call({:tick, ctx}, _from, ids) do
    # Fan-out: each strategy scan/exit may do its own HTTP calls. Running them
    # sequentially in the registry serialises latency across all strategies and
    # blows the 5s default GenServer.call timeout. Running concurrently with
    # Task.async_stream keeps total tick latency ≈ slowest single strategy.
    signals =
      ids
      |> Task.async_stream(
        fn id ->
          AlpacaTrader.StrategyRunner.scan(id, ctx) ++
            AlpacaTrader.StrategyRunner.exits(id, ctx)
        end,
        max_concurrency: max(length(ids), 1),
        timeout: 25_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, sigs} -> sigs
        {:exit, _reason} -> []
      end)

    {:reply, signals, ids}
  end

  def handle_call(:ids, _from, ids), do: {:reply, ids, ids}
end
