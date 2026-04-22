defmodule AlpacaTrader.Scheduler.Jobs.StrategyScanJob do
  @moduledoc """
  Ticks the new StrategyRegistry + routes emitted signals through OrderRouter.

  Runs alongside the legacy `ArbitrageScanJob`: the legacy job keeps driving
  pair-cointegration trading (engine path), while this job drives new
  strategies (FundingBasisArb, etc.). Once legacy is fully ported this job
  becomes the only scan entry point.
  """
  @behaviour AlpacaTrader.Scheduler.Job

  require Logger

  alias AlpacaTrader.{StrategyRegistry, OrderRouter}

  @impl true
  def job_id, do: "strategy-scan"

  @impl true
  def job_name, do: "Strategy Registry Scan"

  @impl true
  def schedule, do: "* * * * *"

  @impl true
  def run do
    ctx = build_context()
    signals = StrategyRegistry.tick(ctx)
    results = Enum.map(signals, &OrderRouter.route/1)

    Logger.info(
      "[StrategyScanJob] signals=#{length(signals)} routed=#{Enum.count(results, &match?({:ok, _}, &1))} rejected=#{Enum.count(results, &match?({:rejected, _}, &1))} dropped=#{Enum.count(results, &match?({:dropped, _}, &1))}"
    )

    {:ok, %{signals: length(signals), outcomes: results}}
  end

  defp build_context do
    %{
      now: DateTime.utc_now(),
      ticks: %{},
      bars: %{}
    }
  end
end
