defmodule Mix.Tasks.Whitelist do
  @moduledoc """
  Generate `priv/runtime/pair_whitelist.json` from walk-forward analysis.

  Runs walk-forward validation on the crypto pair universe and writes a
  whitelist of pairs that pass robustness thresholds. The live engine
  uses this file when `PAIR_WHITELIST_ENABLED=true`.

  ## Usage

      mix whitelist                                   # default params
      mix whitelist --timeframe 15Min --days 30       # finer bars, shorter window
      mix whitelist --min-win-ratio 0.75              # stricter inclusion
      mix whitelist --slippage-bps 30                 # realistic slippage

  The task is idempotent — rerun any time to refresh based on recent regime.
  Consider scheduling it weekly in production.
  """
  use Mix.Task

  @shortdoc "Regenerate pair whitelist from walk-forward analysis"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          days: :integer,
          timeframe: :string,
          slippage_bps: :float,
          min_win_ratio: :float,
          min_avg_return: :float,
          min_trades: :integer,
          entry_z: :float,
          stop_z: :float,
          hedge_mode: :string
        ]
      )

    Mix.Task.run("app.start")

    days = opts[:days] || 90
    timeframe = opts[:timeframe] || "1Hour"
    slippage = opts[:slippage_bps] || 30.0
    min_win_ratio = opts[:min_win_ratio] || 0.66
    min_avg_return = opts[:min_avg_return] || 0.0
    min_trades = opts[:min_trades] || 3

    hedge_mode =
      case opts[:hedge_mode] do
        "kalman" -> :kalman
        _ -> :kalman
      end

    Application.put_env(:alpaca_trader, :hedge_ratio_mode, hedge_mode)

    Mix.shell().info("Fetching bars (#{days}d, #{timeframe})...")
    bars = fetch_universe(days, timeframe)
    bars = Map.filter(bars, fn {_, closes} -> length(closes) >= 160 end)

    if map_size(bars) < 4 do
      Mix.shell().error("Insufficient data: only #{map_size(bars)} symbols with >=160 bars")
      exit({:shutdown, 1})
    end

    min_len = bars |> Map.values() |> Enum.map(&length/1) |> Enum.min()
    bars = Map.new(bars, fn {sym, closes} -> {sym, Enum.take(closes, -min_len)} end)

    pairs =
      all_pairs()
      |> Enum.filter(fn {a, b} -> Map.has_key?(bars, a) and Map.has_key?(bars, b) end)

    Mix.shell().info("Running walk-forward: #{length(pairs)} pairs, #{min_len} bars aligned")

    cfg =
      AlpacaTrader.Backtest.Simulator.default_config()
      |> Map.put(:entry_z, opts[:entry_z] || 1.5)
      |> Map.put(:stop_z, opts[:stop_z] || 5.0)
      |> Map.put(:slippage_bps, slippage)

    window_bars = div(min_len, 2)
    step_bars = max(div(min_len, 4), 30)

    wf =
      AlpacaTrader.Backtest.WalkForward.run(pairs, bars,
        window_bars: window_bars,
        step_bars: step_bars,
        simulator_config: cfg
      )

    if wf.summary[:insufficient_data] do
      Mix.shell().error("Insufficient data for walk-forward")
      exit({:shutdown, 1})
    end

    Mix.shell().info(
      "Full universe: #{wf.summary.n_positive}/#{wf.summary.n_windows} windows positive, " <>
        "avg ret/window #{fmt_pct(wf.summary.avg_portfolio_return)}"
    )

    {:ok, accepted} =
      AlpacaTrader.Backtest.WhitelistGenerator.generate(wf,
        min_win_ratio: min_win_ratio,
        min_avg_return: min_avg_return,
        min_trades: min_trades
      )

    Mix.shell().info("\nWhitelist written: #{length(accepted)} pairs\n")

    Enum.each(accepted, fn {a, b} ->
      Mix.shell().info("  #{a} ↔ #{b}")
    end)

    Mix.shell().info("\nSaved to #{Application.get_env(:alpaca_trader, :pair_whitelist_path)}")
    Mix.shell().info("Enable with: PAIR_WHITELIST_ENABLED=true in your .env")
  end

  defp fetch_universe(days, timeframe) do
    start_date = Date.utc_today() |> Date.add(-days) |> Date.to_iso8601()

    symbols =
      AlpacaTrader.Arbitrage.AssetRelationships.all_symbols()
      |> Enum.filter(&String.contains?(&1, "/"))
      |> Enum.uniq()

    Enum.reduce(symbols, %{}, fn sym, acc ->
      case AlpacaTrader.Alpaca.Client.get_crypto_bars([sym], %{
             timeframe: timeframe,
             limit: 10_000,
             start: start_date
           }) do
        {:ok, %{"bars" => %{^sym => bars}}} when is_list(bars) and bars != [] ->
          closes = bars |> Enum.sort_by(& &1["t"]) |> Enum.map(& &1["c"])
          Map.put(acc, sym, closes)

        _ ->
          acc
      end
    end)
  end

  defp all_pairs do
    syms =
      AlpacaTrader.Arbitrage.AssetRelationships.all_symbols()
      |> Enum.filter(&String.contains?(&1, "/"))
      |> Enum.uniq()

    for i <- 0..(length(syms) - 2),
        j <- (i + 1)..(length(syms) - 1) do
      {Enum.at(syms, i), Enum.at(syms, j)}
    end
  end

  defp fmt_pct(n) when is_number(n), do: :erlang.float_to_binary(n * 100, decimals: 2) <> "%"
  defp fmt_pct(_), do: "0.00%"
end
