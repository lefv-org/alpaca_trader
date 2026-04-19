defmodule AlpacaTrader.RegimeDetector do
  @moduledoc """
  Block pair entries when the market regime is hostile to mean-reversion.

  Two checks, combined as an AND gate:

  1. Realized-volatility of the long leg: annualized stdev of log returns
     over the lookback window. Pair trades blow up in vol spikes — the
     spread's own stdev widens out from the historical distribution, the
     stop-z threshold gets hit on noise, and mean-reversion half-lives
     stretch. High vol is a "sit this one out" signal.

  2. Live spread stationarity: re-runs ADF on the current window's spread.
     A pair that passed walk-forward selection three weeks ago may no
     longer be cointegrated. Blocking on a p-value drift catches silent
     decay without waiting for the weekly re-whitelist job.

  Pure functional. Configured via `:regime_filter_*` application env.
  """

  alias AlpacaTrader.Arbitrage.MeanReversion

  @hourly_bars_per_year 24 * 252
  @min_vol_window 20

  @doc """
  Annualized realized volatility of log returns.

  `bar_frequency` is `:hourly` (default) or `:daily`. Returns a float >= 0
  or `nil` if the series is too short.
  """
  def realized_vol_annualized(series, bar_frequency \\ :hourly)

  def realized_vol_annualized(series, _) when length(series) < @min_vol_window, do: nil

  def realized_vol_annualized(series, bar_frequency) when is_list(series) do
    log_returns =
      series
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn [a, b] -> a > 0 and b > 0 end)
      |> Enum.map(fn [a, b] -> :math.log(b / a) end)

    n = length(log_returns)

    if n < @min_vol_window - 1 do
      nil
    else
      mean = Enum.sum(log_returns) / n

      variance =
        Enum.reduce(log_returns, 0.0, fn r, acc -> acc + :math.pow(r - mean, 2) end) /
          max(n - 1, 1)

      stdev = :math.sqrt(variance)

      scale =
        case bar_frequency do
          :hourly -> :math.sqrt(@hourly_bars_per_year)
          :daily -> :math.sqrt(252)
        end

      stdev * scale
    end
  end

  @doc """
  Gate a pair entry given the current window inputs.

  Inputs:
  - `:spread` — list of spread values over the lookback window
  - `:symbol_a_closes` — closing prices of leg A (used for realized vol)
  - `:bar_frequency` — `:hourly` (default) or `:daily`

  Options:
  - `:enabled` — master switch (default: false)
  - `:max_realized_vol` — annualized stdev ceiling (default: 1.0)
  - `:max_adf_pvalue` — ADF p-value ceiling (default: nil = skip ADF)

  Returns `:ok` or `{:blocked, reason}`.
  """
  def allow_entry?(inputs, opts \\ []) when is_map(inputs) do
    enabled =
      Keyword.get(
        opts,
        :enabled,
        Application.get_env(:alpaca_trader, :regime_filter_enabled, false)
      )

    if not enabled do
      :ok
    else
      max_vol =
        Keyword.get(
          opts,
          :max_realized_vol,
          Application.get_env(:alpaca_trader, :regime_max_realized_vol, 1.0)
        )

      max_adf_p =
        Keyword.get(
          opts,
          :max_adf_pvalue,
          Application.get_env(:alpaca_trader, :regime_max_adf_pvalue)
        )

      bar_freq = Map.get(inputs, :bar_frequency, :hourly)

      with :ok <- check_vol(inputs[:symbol_a_closes] || [], max_vol, bar_freq),
           :ok <- check_adf(inputs[:spread] || [], max_adf_p) do
        :ok
      end
    end
  end

  defp check_vol(closes, max_vol, bar_freq) do
    case realized_vol_annualized(closes, bar_freq) do
      nil -> :ok
      v when v <= max_vol -> :ok
      v -> {:blocked, {:realized_vol_too_high, Float.round(v, 4)}}
    end
  end

  defp check_adf(_spread, nil), do: :ok

  defp check_adf(spread, max_p) when is_list(spread) and length(spread) >= 30 do
    case MeanReversion.adf_test(spread) do
      %{t_stat: t} ->
        if t_to_pvalue(t) <= max_p,
          do: :ok,
          else: {:blocked, {:spread_not_stationary, Float.round(t, 3)}}

      _ ->
        {:blocked, {:spread_not_stationary, :no_adf}}
    end
  end

  defp check_adf(_, _), do: :ok

  defp t_to_pvalue(t) when t <= -3.43, do: 0.01
  defp t_to_pvalue(t) when t <= -2.86, do: 0.05
  defp t_to_pvalue(t) when t <= -2.57, do: 0.10
  defp t_to_pvalue(_), do: 0.50
end
