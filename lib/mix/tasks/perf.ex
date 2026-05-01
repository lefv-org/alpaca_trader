defmodule Mix.Tasks.Perf do
  @moduledoc """
  Print live performance metrics + Kearns omniscient bounds.

  ## Usage

      mix perf                                # report all tracked strategies
      mix perf --symbol AAPL                  # show omniscient bound for AAPL
      mix perf --symbols AAPL,MSFT,SPY        # bounds for multiple
      mix perf --long-only                    # restrict bound to long-only
      mix perf --notional 100                 # nominal $/trade for bound

  Pulls live Sharpe and persistence (Baron-Brogaard 2012) for each
  strategy bucket from the running PerformanceTracker, plus the Kearns
  perfect-foresight upper bound from BarsStore for whatever symbols you
  request. Efficiency = realised / bound.

  Run against the live node via:

      iex -S mix    # then `Mix.Tasks.Perf.run([])`
  """
  use Mix.Task

  alias AlpacaTrader.Analytics.{OmniscientBound, PerformanceTracker}

  @shortdoc "Live Sharpe + Kearns omniscient bound report"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          symbol: :string,
          symbols: :string,
          long_only: :boolean,
          notional: :float,
          spread_bps: :float,
          fee_bps: :float
        ]
      )

    print_strategy_report()
    print_omniscient_bounds(opts)
  end

  defp print_strategy_report do
    IO.puts("\n=== Per-Strategy Performance (Baron-Brogaard 2012 style) ===")

    case PerformanceTracker.report() do
      [] ->
        IO.puts("(no recorded P&L points yet)")

      reports ->
        IO.puts(
          String.pad_trailing("strategy", 28) <>
            String.pad_leading("trades", 8) <>
            String.pad_leading("pnl_total", 12) <>
            String.pad_leading("sharpe", 10) <>
            String.pad_leading("persist", 10) <>
            String.pad_leading("aggr_ratio", 12)
        )

        for r <- reports do
          IO.puts(
            String.pad_trailing(to_string(r.strategy), 28) <>
              String.pad_leading(Integer.to_string(r.points), 8) <>
              String.pad_leading(fmt(r.pnl_total), 12) <>
              String.pad_leading(fmt(r.sharpe), 10) <>
              String.pad_leading(fmt(r.persistence), 10) <>
              String.pad_leading(fmt(r.aggressive_ratio), 12)
          )
        end
    end
  end

  defp print_omniscient_bounds(opts) do
    symbols =
      cond do
        opts[:symbol] -> [opts[:symbol]]
        opts[:symbols] -> String.split(opts[:symbols], ",", trim: true)
        true -> []
      end

    if symbols != [] do
      IO.puts("\n=== Kearns Omniscient Upper Bound ===")

      bound_opts =
        []
        |> add_opt(:long_only, opts[:long_only])
        |> add_opt(:notional, opts[:notional])
        |> add_opt(:spread_bps, opts[:spread_bps])
        |> add_opt(:fee_bps, opts[:fee_bps])

      IO.puts(
        String.pad_trailing("symbol", 12) <>
          String.pad_leading("max_pnl", 12) <>
          String.pad_leading("trades", 10) <>
          String.pad_leading("hit_rate", 12) <>
          String.pad_leading("gross", 12) <>
          String.pad_leading("costs", 12)
      )

      for s <- symbols do
        case OmniscientBound.from_bars_store(s, bound_opts) do
          {:ok, r} ->
            IO.puts(
              String.pad_trailing(s, 12) <>
                String.pad_leading(fmt(r.pnl), 12) <>
                String.pad_leading(Integer.to_string(r.trades), 10) <>
                String.pad_leading(fmt(r.hit_rate), 12) <>
                String.pad_leading(fmt(r.gross), 12) <>
                String.pad_leading(fmt(r.costs), 12)
            )

          {:error, reason} ->
            IO.puts("#{s}: #{inspect(reason)}")
        end
      end
    end
  end

  defp add_opt(kw, _key, nil), do: kw
  defp add_opt(kw, key, val), do: Keyword.put(kw, key, val)

  defp fmt(nil), do: "—"
  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 4)
  defp fmt(n), do: to_string(n)
end
