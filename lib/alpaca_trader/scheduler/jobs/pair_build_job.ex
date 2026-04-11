defmodule AlpacaTrader.Scheduler.Jobs.PairBuildJob do
  @moduledoc """
  Rebuilds the dynamic pair graph every hour by computing
  correlations across all crypto pairs using 1-minute bars.
  """

  @behaviour AlpacaTrader.Scheduler.Job

  alias AlpacaTrader.Arbitrage.PairBuilder

  require Logger

  @impl true
  def job_id, do: "pair-build"

  @impl true
  def job_name, do: "Dynamic Pair Builder"

  @impl true
  def schedule, do: "0 * * * *"

  @impl true
  def run do
    Logger.info("[PairBuildJob] starting pair discovery")

    case PairBuilder.rebuild() do
      {:ok, count} ->
        Logger.info("[PairBuildJob] discovered #{count} correlated pairs")
        {:ok, count}

      {:error, reason} ->
        Logger.error("[PairBuildJob] failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
