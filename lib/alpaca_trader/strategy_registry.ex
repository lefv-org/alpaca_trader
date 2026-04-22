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

  def tick(registry \\ __MODULE__, ctx), do: GenServer.call(registry, {:tick, ctx})

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
    signals =
      Enum.flat_map(ids, fn id ->
        AlpacaTrader.StrategyRunner.scan(id, ctx) ++
          AlpacaTrader.StrategyRunner.exits(id, ctx)
      end)

    {:reply, signals, ids}
  end

  def handle_call(:ids, _from, ids), do: {:reply, ids, ids}
end
