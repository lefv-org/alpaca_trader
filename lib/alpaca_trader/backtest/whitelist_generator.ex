defmodule AlpacaTrader.Backtest.WhitelistGenerator do
  @moduledoc """
  Converts walk-forward results into a pair whitelist.

  Selection rules (defaults, tunable via options):
  - Include pairs with `win_ratio >= :min_win_ratio` (default 0.66)
  - Require `avg_window_return > :min_avg_return` (default 0.0)
  - Require `total_trades >= :min_trades` (default 3)
  - Require `n_windows >= :min_windows` (default 3)
  - Optional `:min_net_sharpe` — rejects pairs whose
    `sharpe_window_annualized` (computed by `WalkForward` from
    slippage-adjusted per-window returns) falls below the threshold. `nil`
    (default) disables this gate.

  Writes the resulting list via `PairWhitelist.replace/1`, which persists
  to `priv/runtime/pair_whitelist.json`.
  """

  alias AlpacaTrader.Arbitrage.PairWhitelist

  require Logger

  @doc """
  Derive a whitelist from `WalkForward.run/3` output and persist it.

  Returns `{:ok, accepted_pairs}` or `{:error, reason}`.
  """
  def generate(walk_forward_result, opts \\ []) do
    min_win_ratio = Keyword.get(opts, :min_win_ratio, 0.66)
    min_avg_return = Keyword.get(opts, :min_avg_return, 0.0)
    min_trades = Keyword.get(opts, :min_trades, 3)
    min_windows = Keyword.get(opts, :min_windows, 3)
    min_net_sharpe = Keyword.get(opts, :min_net_sharpe, nil)

    robustness = walk_forward_result[:per_pair_robustness] || []

    accepted =
      Enum.filter(robustness, fn r ->
        r.n_windows >= min_windows and
          r.total_trades >= min_trades and
          r.win_ratio >= min_win_ratio and
          r.avg_window_return > min_avg_return and
          (is_nil(min_net_sharpe) or Map.get(r, :sharpe_window_annualized, 0.0) >= min_net_sharpe)
      end)

    tuples =
      Enum.map(accepted, fn r ->
        case String.split(r.pair, "-", parts: 2) do
          [a, b] -> {a, b}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    PairWhitelist.replace(tuples)

    sharpe_clause =
      if is_nil(min_net_sharpe), do: "", else: ", net_sharpe≥#{min_net_sharpe}"

    Logger.info(
      "[WhitelistGenerator] wrote #{length(tuples)} pairs " <>
        "(from #{length(robustness)} evaluated, win_ratio≥#{min_win_ratio}, " <>
        "avg_ret>#{min_avg_return}, trades≥#{min_trades}#{sharpe_clause})"
    )

    {:ok, tuples}
  end
end
