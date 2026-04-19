defmodule Mix.Tasks.Backtest do
  @moduledoc """
  Run a backtest against the crypto pair universe.

  ## Usage

      mix backtest                                     # 30d, 1Hour, 20 pairs
      mix backtest --days 90 --timeframe 1Hour         # 90d window
      mix backtest --max-pairs 50                      # broader sweep
      mix backtest --vol-scaled                        # enable vol sizing
      mix backtest --strict-coint                      # tighter ADF filter

  The task prints a portfolio summary and the top 10 pairs by trade count.
  No orders are submitted to Alpaca.
  """
  use Mix.Task

  @shortdoc "Backtest the pair-trading strategy against historical bars"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          days: :integer,
          timeframe: :string,
          max_pairs: :integer,
          vol_scaled: :boolean,
          strict_coint: :boolean,
          entry_z: :float,
          exit_z: :float,
          stop_z: :float,
          slippage_bps: :float
        ]
      )

    # Start only what we need — Alpaca client, stores, asset_relationships.
    Mix.Task.run("app.start")

    days = opts[:days] || 30
    timeframe = opts[:timeframe] || "1Hour"
    max_pairs = opts[:max_pairs] || 20

    sim_cfg = build_sim_config(opts)

    Mix.shell().info("Running backtest: #{days}d, #{timeframe}, #{max_pairs} pairs")
    Mix.shell().info("Simulator config: #{inspect(sim_cfg)}")

    result =
      AlpacaTrader.Backtest.Runner.run_crypto_universe(
        days: days,
        timeframe: timeframe,
        max_pairs: max_pairs,
        simulator_config: sim_cfg
      )

    print_report(result)
  end

  defp build_sim_config(opts) do
    base =
      AlpacaTrader.Backtest.Simulator.default_config()
      |> Map.put(:entry_z, opts[:entry_z] || 2.0)
      |> Map.put(:exit_z, opts[:exit_z] || 0.5)
      |> Map.put(:stop_z, opts[:stop_z] || 4.0)
      |> Map.put(:slippage_bps, opts[:slippage_bps] || 10.0)

    base =
      if opts[:vol_scaled] do
        Map.put(base, :position_sizing, :vol_scaled)
      else
        base
      end

    base =
      if opts[:strict_coint] do
        base
        |> Map.put(:max_half_life, 30)
        |> Map.put(:max_hurst, 0.65)
      else
        base
      end

    base
  end

  defp print_report(%{per_pair: per_pair, portfolio: portfolio} = _result) do
    all_trades = Enum.flat_map(per_pair, &(&1[:trades] || []))

    Mix.shell().info("\n======== PORTFOLIO ========")
    Mix.shell().info("trades: #{portfolio.n_trades}")
    Mix.shell().info("win_rate: #{fmt_pct(portfolio.win_rate)}")
    Mix.shell().info("avg_win: #{fmt_pct(portfolio.avg_win_pct)}")
    Mix.shell().info("avg_loss: #{fmt_pct(portfolio.avg_loss_pct)}")
    Mix.shell().info("profit_factor: #{format_pf(portfolio.profit_factor)}")
    Mix.shell().info("total_return: #{fmt_pct(portfolio.total_return_pct)}")
    Mix.shell().info("sharpe (annualized): #{portfolio.sharpe_daily_annualized}")
    Mix.shell().info("max_drawdown: #{fmt_pct(portfolio.max_drawdown_pct)}")
    Mix.shell().info("avg_hold: #{portfolio.avg_hold_bars} bars")
    Mix.shell().info("exit_reasons: #{inspect(portfolio.exit_reasons)}")

    Mix.shell().info("\n======== TOP PAIRS BY TRADES ========")

    per_pair
    |> Enum.filter(fn r -> length(r[:trades] || []) > 0 end)
    |> Enum.sort_by(fn r -> -length(r[:trades] || []) end)
    |> Enum.take(10)
    |> Enum.each(fn r ->
      summary = AlpacaTrader.Backtest.Report.summarize(r)

      Mix.shell().info(
        "#{String.pad_trailing(r[:pair], 16)} " <>
          "n=#{String.pad_leading(to_string(summary.n_trades), 3)} " <>
          "wr=#{fmt_pct(summary.win_rate)} " <>
          "ret=#{fmt_pct(summary.total_return_pct)} " <>
          "avg_hold=#{Float.round(summary.avg_hold_bars * 1.0, 1)}b " <>
          "mdd=#{fmt_pct(summary.max_drawdown_pct)}"
      )
    end)

    if length(all_trades) == 0 do
      Mix.shell().info(
        "\nNo trades generated. Check: (1) pair cointegration gate too strict, (2) entry z too high, (3) insufficient historical bars."
      )
    end
  end

  defp fmt_pct(n) when is_number(n), do: :erlang.float_to_binary(n * 100, decimals: 2) <> "%"
  defp fmt_pct(_), do: "0.00%"
  defp format_pf(:infinity), do: "∞"
  defp format_pf(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)
end
