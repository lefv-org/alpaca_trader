defmodule AlpacaTrader.Arbitrage.KellySizer do
  @moduledoc """
  Kelly-fractional sizing cap derived from walk-forward statistics.

  Full Kelly for a binary-outcome bet is

      f* = (p * b - q) / b

  where p is win probability, q = 1-p, and b is the payoff ratio
  (avg_win / avg_loss). Full Kelly maximizes long-run log growth but
  produces brutal drawdowns; in practice traders use fractional Kelly
  (half or quarter) and cap the fraction at a hard ceiling so a
  stale/overfit edge estimate cannot size the book into ruin.

  This module only computes a *ceiling* on notional; the engine's
  existing vol-scaled sizing still picks the actual amount. Kelly is
  opt-in and off by default.
  """

  @doc "Full Kelly fraction, clamped to [0, 1]."
  def kelly_fraction(win_rate, avg_win_pct, avg_loss_pct)
      when is_number(win_rate) and win_rate > 0 and win_rate < 1 and
             is_number(avg_win_pct) and avg_win_pct > 0 and
             is_number(avg_loss_pct) and avg_loss_pct > 0 do
    b = avg_win_pct / avg_loss_pct
    p = win_rate
    q = 1.0 - p

    raw = (p * b - q) / b
    raw |> max(0.0) |> min(1.0)
  end

  def kelly_fraction(_, _, _), do: 0.0

  @doc """
  Size cap in dollars.

  `stats` is a map with `:win_rate`, `:avg_win_pct`, `:avg_loss_pct`.
  When any key is missing or invalid, `kelly_fraction/3` returns 0.0 which
  collapses the Kelly fraction term; the dollar cap then becomes 0. To keep
  Kelly from silently *zeroing* sizing when stats aren't yet warmed up, the
  caller's fallback path should skip the Kelly clip entirely when stats are
  empty. For the simple unit case where stats are missing, we return
  `equity * max_cap_pct` (the hard policy ceiling) so callers that delegate
  the fallback to this function get a sane default.
  """
  def size_cap(equity, stats, opts \\ [])

  def size_cap(equity, stats, opts) when is_number(equity) and equity > 0 and is_map(stats) do
    fraction = Keyword.get(opts, :fraction, 0.5)
    max_cap_pct = Keyword.get(opts, :max_cap_pct, 0.10)

    win_rate = Map.get(stats, :win_rate)
    avg_win_pct = Map.get(stats, :avg_win_pct)
    avg_loss_pct = Map.get(stats, :avg_loss_pct)

    if is_nil(win_rate) or is_nil(avg_win_pct) or is_nil(avg_loss_pct) do
      # No warm stats → fall back to the hard policy ceiling
      equity * max_cap_pct
    else
      f_star = kelly_fraction(win_rate, avg_win_pct, avg_loss_pct)
      fractional = f_star * fraction
      pct = min(fractional, max_cap_pct)
      equity * pct
    end
  end

  def size_cap(_, _, _), do: 0.0
end
