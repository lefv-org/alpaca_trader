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
      bars: %{},
      positions: load_positions()
    }
  end

  # Pull live Alpaca positions so strategies can compute inventory skew
  # (Avellaneda-Stoikov) and avoid emitting fresh BUY signals on
  # already-heavy holdings. Quietly returns an empty map on failure —
  # strategies treat missing positions as q=0 just like before this fix.
  # Symbol keys mirror Alpaca's no-slash form (ETHUSD, BTCUSD); strategies
  # that quote the slash form should normalise themselves.
  defp load_positions do
    case AlpacaTrader.Alpaca.Client.list_positions() do
      {:ok, list} when is_list(list) ->
        for p <- list, into: %{} do
          symbol = p["symbol"]
          qty = parse_num(p["qty"])
          mv = parse_num(p["market_value"])
          # Also expose under slash-form for crypto so AvellanedaStoikov
          # (whitelist symbols stored without slash) and any future
          # crypto-MM strategy (whitelist with slash) both find a hit.
          slash = if String.contains?(symbol, "USD") and not String.contains?(symbol, "/") do
            base = String.replace_suffix(symbol, "USD", "")
            "#{base}/USD"
          end

          entry = %{qty: qty, market_value: mv, side: p["side"]}
          base = %{symbol => entry}
          if slash, do: Map.put(base, slash, entry), else: base
        end
        |> Enum.reduce(%{}, &Map.merge(&2, &1))

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp parse_num(nil), do: 0.0
  defp parse_num(n) when is_number(n), do: n * 1.0

  defp parse_num(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end
