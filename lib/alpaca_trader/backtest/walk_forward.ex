defmodule AlpacaTrader.Backtest.WalkForward do
  @moduledoc """
  Walk-forward validation across rolling train/test windows.

  The single-window backtest answers "did the strategy make money in period X?"
  but a 90-day positive result can easily be lookback-bias, regime luck, or
  parameter overfitting. Walk-forward slides a window across the full history
  and asks "is the strategy consistently positive across MOST windows?" That's
  the real test of whether an edge exists.

  Two modes:

  - `:fixed_params` (default): runs the same config across every window. Good
    for detecting regime dependence — if a config is profitable in 5/8 windows
    and breakeven in 3/8, that's a real if regime-sensitive edge. If it wins
    2/8 and loses 6/8, there's no edge.

  - `:tune_and_test`: on each window, tune parameters on the train segment
    then evaluate on the test segment. Protects against overfitting — a tuned
    result is only "real" if the OOS test segment also wins. We don't ship
    this by default; fixed-params is the more skeptical test.

  Reports per-window summary plus robustness metrics (pairs that win in X% of
  windows, win-rate variance across windows, etc).

  Sharpe annualization assumes hourly bars; the factor is derived from
  `window_bars` (e.g., 720-bar windows → ~8.4 windows/year → annualization ≈
  sqrt(8.4)).
  """

  alias AlpacaTrader.Backtest.{Simulator, Report}

  @type window_result :: %{
          window_index: non_neg_integer(),
          start_bar: non_neg_integer(),
          end_bar: non_neg_integer(),
          portfolio: map(),
          per_pair: list()
        }

  @doc """
  Run fixed-parameter walk-forward across a set of pairs.

  `bars_map` — `%{"SYMBOL" => [close_1, close_2, ...]}`. Must be aligned (same
  length across all symbols) or `min_length` is used.

  Options:
  - `:window_bars` (default 720) — backtest window size in bars (30 days @ hourly)
  - `:step_bars` (default 240) — stride between windows (10 days @ hourly)
  - `:simulator_config` — passed to each Simulator.run_pair call
  """
  def run(pairs, bars_map, opts \\ []) do
    window_bars = Keyword.get(opts, :window_bars, 720)
    step_bars = Keyword.get(opts, :step_bars, 240)
    sim_cfg = Keyword.get(opts, :simulator_config, %{})

    min_len =
      pairs
      |> Enum.flat_map(fn {a, b} -> [Map.get(bars_map, a, []), Map.get(bars_map, b, [])] end)
      |> Enum.filter(&(length(&1) > 0))
      |> Enum.map(&length/1)
      |> Enum.min(fn -> 0 end)

    if min_len < window_bars + step_bars do
      %{
        windows: [],
        per_pair_robustness: [],
        summary: %{
          insufficient_data: true,
          min_len: min_len,
          required: window_bars + step_bars
        }
      }
    else
      window_starts = 0..(min_len - window_bars)//step_bars |> Enum.to_list()

      windows =
        window_starts
        |> Enum.with_index()
        |> Enum.map(fn {start, idx} ->
          run_window(idx, start, window_bars, pairs, bars_map, sim_cfg)
        end)

      %{
        windows: windows,
        per_pair_robustness: compute_pair_robustness(windows, window_bars),
        summary: summarize_windows(windows)
      }
    end
  end

  defp run_window(idx, start, window_bars, pairs, bars_map, sim_cfg) do
    per_pair =
      Enum.map(pairs, fn {a, b} ->
        ca = Map.get(bars_map, a, [])
        cb = Map.get(bars_map, b, [])
        ca_w = Enum.slice(ca, start, window_bars)
        cb_w = Enum.slice(cb, start, window_bars)

        if length(ca_w) == window_bars and length(cb_w) == window_bars do
          Simulator.run_pair("#{a}-#{b}", ca_w, cb_w, sim_cfg)
          |> Map.put(:pair, "#{a}-#{b}")
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    %{
      window_index: idx,
      start_bar: start,
      end_bar: start + window_bars,
      portfolio: Report.aggregate(per_pair),
      per_pair: per_pair
    }
  end

  # For each pair, count how many windows produced positive returns.
  defp compute_pair_robustness(windows, window_bars) do
    annualization = :math.sqrt(max(24 * 252 / window_bars, 1.0))

    all_pairs =
      windows
      |> Enum.flat_map(fn w -> Enum.map(w.per_pair, & &1.pair) end)
      |> Enum.uniq()

    Enum.map(all_pairs, fn pair_name ->
      window_results =
        windows
        |> Enum.map(fn w -> Enum.find(w.per_pair, &(&1.pair == pair_name)) end)
        |> Enum.reject(&is_nil/1)

      per_window_returns =
        Enum.map(window_results, fn r ->
          Enum.reduce(r[:trades] || [], 0.0, fn t, acc -> acc + t.pnl_pct end)
        end)

      total_trades =
        Enum.reduce(window_results, 0, fn r, acc -> acc + length(r[:trades] || []) end)

      wins = Enum.count(per_window_returns, &(&1 > 0))
      n = length(per_window_returns)
      avg_ret = if n > 0, do: Enum.sum(per_window_returns) / n, else: 0.0

      sharpe_window_annualized =
        cond do
          n <= 1 ->
            0.0

          true ->
            var =
              Enum.reduce(per_window_returns, 0.0, fn r, acc ->
                acc + :math.pow(r - avg_ret, 2)
              end) /
                (n - 1)

            std = :math.sqrt(var)
            if std > 0, do: Float.round(avg_ret / std * annualization, 4), else: 0.0
        end

      %{
        pair: pair_name,
        n_windows: n,
        wins: wins,
        win_ratio: if(n > 0, do: wins / n, else: 0.0),
        avg_window_return: avg_ret,
        total_trades: total_trades,
        per_window_returns: per_window_returns,
        sharpe_window_annualized: sharpe_window_annualized
      }
    end)
    |> Enum.sort_by(&(-&1.win_ratio))
  end

  defp summarize_windows(windows) do
    n = length(windows)
    portfolio_returns = Enum.map(windows, fn w -> w.portfolio.total_return_pct end)

    positive = Enum.count(portfolio_returns, &(&1 > 0))
    avg_ret = if n > 0, do: Enum.sum(portfolio_returns) / n, else: 0.0

    # Variance in portfolio returns across windows
    variance =
      if n > 1 do
        Enum.reduce(portfolio_returns, 0.0, fn r, acc -> acc + :math.pow(r - avg_ret, 2) end) /
          (n - 1)
      else
        0.0
      end

    %{
      n_windows: n,
      n_positive: positive,
      positive_ratio: if(n > 0, do: positive / n, else: 0.0),
      avg_portfolio_return: avg_ret,
      stddev_portfolio_return: :math.sqrt(variance),
      min_window_return: Enum.min(portfolio_returns, fn -> 0.0 end),
      max_window_return: Enum.max(portfolio_returns, fn -> 0.0 end),
      per_window_returns: portfolio_returns
    }
  end
end
