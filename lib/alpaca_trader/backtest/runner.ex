defmodule AlpacaTrader.Backtest.Runner do
  @moduledoc """
  Orchestrates a backtest across multiple pairs. Pulls historical bars from
  Alpaca, runs each pair through `Backtest.Simulator`, and aggregates results
  via `Backtest.Report`.

  Designed to be invoked from a one-off shell command or iex session, not
  on the scheduler — Alpaca rate-limits matter when pulling 90+ days of bars
  across 50+ symbols.

  Typical usage:

      iex> AlpacaTrader.Backtest.Runner.run_crypto_universe(
      ...>   days: 90, timeframe: "1Hour", max_pairs: 30
      ...> )

  Returns a map: `%{per_pair: [...], portfolio: %{metrics}, config: %{...}}`.
  """

  alias AlpacaTrader.Alpaca.Client
  alias AlpacaTrader.Backtest.{Simulator, Report}
  alias AlpacaTrader.Arbitrage.AssetRelationships

  require Logger

  @doc """
  Run a backtest on the crypto pair universe.

  Options:
  - `:days` (default 90) — lookback window
  - `:timeframe` (default "1Hour") — Alpaca bar timeframe
  - `:max_pairs` (default 50) — cap on pairs to test
  - `:simulator_config` — override backtest Simulator defaults
  """
  def run_crypto_universe(opts \\ []) do
    days = Keyword.get(opts, :days, 90)
    timeframe = Keyword.get(opts, :timeframe, "1Hour")
    max_pairs = Keyword.get(opts, :max_pairs, 50)
    sim_cfg = Keyword.get(opts, :simulator_config, %{})

    pairs = crypto_pairs_from_relationships() |> Enum.take(max_pairs)

    Logger.info("[Backtest] running #{length(pairs)} crypto pairs over #{days}d @ #{timeframe}")

    start_date = Date.utc_today() |> Date.add(-days) |> Date.to_iso8601()

    symbols = pairs |> Enum.flat_map(fn {a, b} -> [a, b] end) |> Enum.uniq()
    bars_map = fetch_all(symbols, timeframe, start_date)

    per_pair =
      pairs
      |> Enum.map(fn {a, b} -> run_pair_with_bars(a, b, bars_map, sim_cfg) end)
      |> Enum.reject(&is_nil/1)

    portfolio = Report.aggregate(per_pair)

    %{
      per_pair: per_pair,
      portfolio: portfolio,
      config: %{days: days, timeframe: timeframe, max_pairs: max_pairs, sim: sim_cfg}
    }
  end

  @doc """
  Run a single pair by symbol names, using whatever data is already in
  `BarsStore` (fast path for iteration).
  """
  def run_from_bars_store(asset_a, asset_b, opts \\ []) do
    sim_cfg = Keyword.get(opts, :simulator_config, %{})

    with {:ok, ca} <- AlpacaTrader.BarsStore.get_closes(asset_a),
         {:ok, cb} <- AlpacaTrader.BarsStore.get_closes(asset_b) do
      label = "#{asset_a}-#{asset_b}"
      result = Simulator.run_pair(label, ca, cb, sim_cfg)
      Map.put(result, :pair, label)
    else
      _ -> nil
    end
  end

  @doc """
  Pretty-print a portfolio summary to Logger and as a map.
  """
  def report(%{per_pair: per_pair, portfolio: portfolio}) do
    Logger.info("[Backtest] ====== PORTFOLIO ======")
    Logger.info("[Backtest] " <> Report.to_string(%{trades: flatten_trades(per_pair), equity_curve: []}))

    Logger.info("[Backtest] portfolio metrics: #{inspect(portfolio)}")

    Logger.info("[Backtest] ====== PER PAIR (top 10 by trades) ======")

    per_pair
    |> Enum.sort_by(fn r -> -length(r[:trades] || []) end)
    |> Enum.take(10)
    |> Enum.each(fn r ->
      if (r[:trades] || []) != [] do
        summary = Report.summarize(r)
        Logger.info("[Backtest]   #{r[:pair]}: n=#{summary.n_trades} wr=#{pct(summary.win_rate)} ret=#{pct(summary.total_return_pct)} avg_hold=#{round1(summary.avg_hold_bars)}b")
      end
    end)

    :ok
  end

  # ── internals ──────────────────────────────────────────────

  defp crypto_pairs_from_relationships do
    # AssetRelationships has hardcoded pair groupings. Extract pairs from them.
    syms = AssetRelationships.all_symbols() |> Enum.filter(&String.contains?(&1, "/"))

    # All (a, b) combos, sorted to stabilize output
    for i <- 0..(length(syms) - 2),
        j <- (i + 1)..(length(syms) - 1) do
      {Enum.at(syms, i), Enum.at(syms, j)}
    end
  end

  defp fetch_all(symbols, timeframe, start_date) do
    # Fetch one symbol at a time to stay under Alpaca's URL-length cap.
    # Runs sequentially — tune with Task.async_stream if API rate allows.
    symbols
    |> Enum.reduce(%{}, fn sym, acc ->
      case Client.get_crypto_bars([sym], %{timeframe: timeframe, limit: 10_000, start: start_date}) do
        {:ok, %{"bars" => %{^sym => bars}}} when is_list(bars) and bars != [] ->
          closes = bars |> Enum.sort_by(& &1["t"]) |> Enum.map(& &1["c"])
          Map.put(acc, sym, closes)

        _ ->
          Logger.warning("[Backtest] no bars for #{sym}")
          acc
      end
    end)
  end

  defp run_pair_with_bars(a, b, bars_map, sim_cfg) do
    case {Map.get(bars_map, a), Map.get(bars_map, b)} do
      {ca, cb} when is_list(ca) and is_list(cb) and length(ca) >= 60 and length(cb) >= 60 ->
        label = "#{a}-#{b}"

        # Align lengths — use shorter series
        l = min(length(ca), length(cb))
        ca_aligned = Enum.take(ca, -l)
        cb_aligned = Enum.take(cb, -l)

        result = Simulator.run_pair(label, ca_aligned, cb_aligned, sim_cfg)
        Map.put(result, :pair, label)

      _ ->
        nil
    end
  end

  defp flatten_trades(per_pair) do
    Enum.flat_map(per_pair, fn r -> r[:trades] || [] end)
  end

  defp pct(n) when is_number(n), do: :erlang.float_to_binary(n * 100, decimals: 2) <> "%"
  defp pct(_), do: "0.00%"

  defp round1(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 1)
  defp round1(_), do: "0.0"
end
