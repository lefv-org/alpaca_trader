defmodule AlpacaTrader.Scheduler.Jobs.PairRecointegrationJob do
  @moduledoc """
  Weekly job that re-validates every whitelisted pair against fresh bars.

  A pair that passed walk-forward six months ago may no longer cointegrate —
  the underlying relationship can break quietly (regime change, business
  model shift, delisting of a substitute). Waiting for the monthly full
  walk-forward cycle leaves the engine placing bets on broken pairs.

  This job runs ADF + half-life on the most recent `:recointegration_lookback_bars`
  bars for each whitelisted pair and removes any pair that fails. It logs a
  structured report of retained vs evicted pairs.
  """

  @behaviour AlpacaTrader.Scheduler.Job

  alias AlpacaTrader.Arbitrage.{MeanReversion, PairWhitelist, SpreadCalculator}
  alias AlpacaTrader.BarsStore

  require Logger

  @impl true
  def job_id, do: "pair-recointegration"

  @impl true
  def job_name, do: "Pair Re-Cointegration Refresh"

  # Sundays at 06:00 UTC — quiet window for most markets.
  @impl true
  def schedule, do: "0 6 * * 0"

  @impl true
  def run do
    pairs = PairWhitelist.list()
    bars = fetch_current_bars(pairs)
    {:ok, report} = evaluate(pairs, bars)

    :ok = PairWhitelist.replace(report.retained)

    Logger.info(
      "[PairRecointegrationJob] retained #{length(report.retained)}, evicted #{length(report.evicted)}"
    )

    :ok
  end

  @spec evaluate([{String.t(), String.t()}], map()) ::
          {:ok, %{retained: [{String.t(), String.t()}], evicted: [{String.t(), String.t()}]}}
  def evaluate(pairs, bars_map) do
    {retained, evicted} =
      Enum.split_with(pairs, fn {a, b} ->
        ca = Map.get(bars_map, a, [])
        cb = Map.get(bars_map, b, [])

        cond do
          length(ca) < 100 or length(cb) < 100 ->
            # Insufficient data → keep the pair; the next scan will handle it.
            true

          true ->
            passes_cointegration?(ca, cb)
        end
      end)

    {:ok, %{retained: retained, evicted: evicted}}
  end

  defp passes_cointegration?(ca, cb) do
    case SpreadCalculator.analyze(ca, cb) do
      %{hedge_ratio: hedge_ratio} ->
        spread = SpreadCalculator.spread_series(ca, cb, hedge_ratio)
        match?({:ok, _}, MeanReversion.classify(spread, max_half_life: 60))

      _ ->
        # analyze/2 returns nil when inputs are unusable — treat as pass so
        # the pair is retained until the next scan has better data.
        true
    end
  end

  defp fetch_current_bars(pairs) do
    lookback = Application.get_env(:alpaca_trader, :recointegration_lookback_bars, 500)

    pairs
    |> Enum.flat_map(fn {a, b} -> [a, b] end)
    |> Enum.uniq()
    |> Enum.map(fn sym -> {sym, BarsStore.recent_closes(sym, lookback)} end)
    |> Map.new()
  end
end
