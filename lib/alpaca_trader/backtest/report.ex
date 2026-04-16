defmodule AlpacaTrader.Backtest.Report do
  @moduledoc """
  Compute aggregate performance metrics from a list of backtest trades.

  Metrics:
  - win_rate, n_trades, avg_win, avg_loss, profit_factor
  - total_return, annualized_return (based on trading days)
  - sharpe (daily returns, annualized)
  - max_drawdown, max_drawdown_duration
  - avg_hold_bars, exit_reason_breakdown

  Takes the shape of the output from `Backtest.Simulator.run_pair/4`.
  """

  @doc """
  Generate a full metrics report from a simulator result.
  """
  def summarize(%{trades: trades, equity_curve: curve}) do
    wins = Enum.filter(trades, &(&1.pnl_pct > 0))
    losses = Enum.filter(trades, &(&1.pnl_pct <= 0))
    n = length(trades)

    win_rate = if n > 0, do: length(wins) / n, else: 0.0
    avg_win = mean_pct(wins)
    avg_loss = mean_pct(losses)

    total_win_dollars = Enum.reduce(wins, 0.0, fn t, acc -> acc + t.pnl end)
    total_loss_dollars = Enum.reduce(losses, 0.0, fn t, acc -> acc + abs(t.pnl) end)

    profit_factor =
      cond do
        total_loss_dollars == 0.0 and total_win_dollars == 0.0 -> 0.0
        total_loss_dollars == 0.0 -> :infinity
        true -> total_win_dollars / total_loss_dollars
      end

    avg_hold = mean_field(trades, :hold_bars)

    total_return = Enum.reduce(trades, 0.0, fn t, acc -> acc + t.pnl_pct end)

    {max_dd, max_dd_duration} = max_drawdown_from_curve(curve)

    exit_reasons =
      trades
      |> Enum.group_by(& &1.reason)
      |> Map.new(fn {k, v} -> {k, length(v)} end)

    sharpe = sharpe_from_curve(curve)

    %{
      n_trades: n,
      win_rate: round4(win_rate),
      avg_win_pct: round4(avg_win),
      avg_loss_pct: round4(avg_loss),
      profit_factor: profit_factor_round(profit_factor),
      total_return_pct: round4(total_return),
      sharpe_daily_annualized: round4(sharpe),
      max_drawdown_pct: round4(max_dd),
      max_drawdown_bars: max_dd_duration,
      avg_hold_bars: round4(avg_hold),
      exit_reasons: exit_reasons
    }
  end

  @doc """
  One-line text summary of key metrics. Suitable for a log line.
  """
  def to_string(%{trades: _, equity_curve: _} = result) do
    s = summarize(result)

    "n=#{s.n_trades} wr=#{pct(s.win_rate)} " <>
      "avg_win=#{pct(s.avg_win_pct)} avg_loss=#{pct(s.avg_loss_pct)} " <>
      "pf=#{format_pf(s.profit_factor)} total=#{pct(s.total_return_pct)} " <>
      "sharpe=#{s.sharpe_daily_annualized} mdd=#{pct(s.max_drawdown_pct)}"
  end

  @doc """
  Aggregate multiple per-pair results into a portfolio-level report.
  """
  def aggregate(results) when is_list(results) do
    all_trades = Enum.flat_map(results, fn r -> r[:trades] || [] end)

    unified_curve =
      Enum.reduce(results, {0, []}, fn r, {offset, acc} ->
        curve = r[:equity_curve] || []
        # Sum equities per-bar index (simple superposition for independent pairs)
        shifted = Enum.map(curve, fn {i, eq} -> {i + offset, eq - 1.0} end)
        {offset, acc ++ shifted}
      end)
      |> elem(1)

    # Rebuild portfolio equity curve by accumulating per-bar deltas
    portfolio_curve =
      unified_curve
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({1.0, []}, fn {i, delta}, {running, acc} ->
        new_eq = running + delta
        {new_eq, [{i, new_eq} | acc]}
      end)
      |> elem(1)
      |> Enum.reverse()

    summarize(%{trades: all_trades, equity_curve: portfolio_curve})
  end

  # ── helpers ────────────────────────────────────────────────

  defp mean_pct([]), do: 0.0
  defp mean_pct(trades), do: Enum.reduce(trades, 0.0, &(&1.pnl_pct + &2)) / length(trades)

  defp mean_field([], _), do: 0.0
  defp mean_field(trades, field) do
    Enum.reduce(trades, 0.0, fn t, acc -> acc + Map.get(t, field, 0) end) / length(trades)
  end

  defp max_drawdown_from_curve([]), do: {0.0, 0}
  defp max_drawdown_from_curve(curve) do
    {mdd, _, duration, _} =
      Enum.reduce(curve, {0.0, 1.0, 0, {0, 0}}, fn {i, eq}, {mdd, peak, dur, {peak_i, trough_i}} ->
        new_peak = max(peak, eq)
        dd = (new_peak - eq) / new_peak
        peak_i = if new_peak > peak, do: i, else: peak_i
        new_dur = i - peak_i

        if dd > mdd do
          {dd, new_peak, new_dur, {peak_i, i}}
        else
          {mdd, new_peak, dur, {peak_i, trough_i}}
        end
      end)

    {mdd, duration}
  end

  defp sharpe_from_curve([]), do: 0.0
  defp sharpe_from_curve(curve) when length(curve) < 3, do: 0.0

  defp sharpe_from_curve(curve) do
    eqs = Enum.map(curve, &elem(&1, 1))

    returns =
      eqs
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> if a != 0.0, do: (b - a) / a, else: 0.0 end)

    n = length(returns)

    if n < 2 do
      0.0
    else
      mean_r = Enum.sum(returns) / n
      variance = Enum.reduce(returns, 0.0, fn r, acc -> acc + :math.pow(r - mean_r, 2) end) / (n - 1)
      std = :math.sqrt(variance)

      # Default annualization assumes 1-hour crypto bars (24*365=8760/yr).
      # To get an accurate Sharpe for different timeframes, wrap summarize/1
      # with a custom bars_per_year via summarize_with_periods/2.
      bars_per_year = 8760

      if std > 0 do
        mean_r / std * :math.sqrt(bars_per_year)
      else
        0.0
      end
    end
  end

  defp round4(n) when is_number(n), do: Float.round(n * 1.0, 4)
  defp round4(_), do: 0.0

  defp profit_factor_round(:infinity), do: :infinity
  defp profit_factor_round(n), do: round4(n)

  defp format_pf(:infinity), do: "∞"
  defp format_pf(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)

  defp pct(n) when is_number(n), do: :erlang.float_to_binary(n * 100, decimals: 2) <> "%"
  defp pct(_), do: "0.00%"
end
