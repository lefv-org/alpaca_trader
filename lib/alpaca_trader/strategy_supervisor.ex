defmodule AlpacaTrader.StrategySupervisor do
  @moduledoc "DynamicSupervisor for Strategy GenServer runners."
  use DynamicSupervisor

  def start_link(_opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_strategy(mod, config) do
    spec = {AlpacaTrader.StrategyRunner, {mod, config}}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
