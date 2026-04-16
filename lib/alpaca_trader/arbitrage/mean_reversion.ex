defmodule AlpacaTrader.Arbitrage.MeanReversion do
  @moduledoc """
  Statistical primitives for testing mean reversion in a spread series.

  Three key tests, each answering a distinct question:

  - `adf_test/1` — IS the spread stationary? (Dickey-Fuller t-stat vs critical value.)
  - `half_life/1` — HOW FAST does it revert? (Ornstein-Uhlenbeck half-life in bars.)
  - `hurst_exponent/1` — REGIME: mean-reverting (H<0.5) vs trending (H>0.5)?

  Used as admission criteria for `PairBuilder` and as a regime filter for
  the entry logic in `Engine`. Pure functional — no side effects.
  """

  @doc """
  Dickey-Fuller test for unit root on a spread series.

  Model: Δy_t = α + γ·y_{t-1} + ε_t
  Null:  γ = 0   (unit root, series is non-stationary, no mean reversion)
  Alt:   γ < 0   (stationary, mean-reverting)

  Returns a map: `%{t_stat: float, gamma: float, stationary?: bool,
  critical_5pct: float}`.
  The series is stationary (tradeable) if `t_stat < -2.86` (5% critical value
  for n > 100 with constant only, MacKinnon 1996).

  Returns `nil` for series shorter than 30 points.
  """
  def adf_test(series) when is_list(series) and length(series) >= 30 do
    # Build lagged and differenced series
    #   y_lag = series[0..n-2]
    #   dy    = series[1..n-1] - series[0..n-2]
    {y_lag, dy} = build_lagged_and_diffed(series)

    # OLS: dy = α + γ·y_lag + ε
    # Closed form for simple linear regression with intercept
    case ols_simple(y_lag, dy) do
      {:ok, %{slope: gamma, slope_se: gamma_se}} when gamma_se > 0 ->
        t_stat = gamma / gamma_se
        critical_5pct = -2.86

        %{
          t_stat: Float.round(t_stat, 4),
          gamma: Float.round(gamma, 6),
          stationary?: t_stat < critical_5pct,
          critical_5pct: critical_5pct
        }

      _ ->
        nil
    end
  end

  def adf_test(_), do: nil

  @doc """
  Ornstein-Uhlenbeck half-life of mean reversion in bars.

  From the AR(1) fit y_t = (1+γ)·y_{t-1} + α + ε:
  half_life = -ln(2) / ln(1+γ)

  Returns nil if γ >= 0 (no reversion) or the series is too short.
  """
  def half_life(series) when is_list(series) and length(series) >= 30 do
    {y_lag, dy} = build_lagged_and_diffed(series)

    case ols_simple(y_lag, dy) do
      {:ok, %{slope: gamma}} when gamma < 0 and gamma > -2.0 ->
        rho = 1.0 + gamma
        # rho must be in (0, 1) for a valid half-life
        if rho > 0 and rho < 1 do
          hl = -:math.log(2) / :math.log(rho)
          Float.round(hl, 2)
        end

      _ ->
        nil
    end
  end

  def half_life(_), do: nil

  @doc """
  Hurst exponent via rescaled range (R/S) analysis.

  - H ≈ 0.5 → random walk (no memory)
  - H < 0.5 → mean-reverting (anti-persistent)
  - H > 0.5 → trending (persistent)

  Returns a float in approximately [0, 1]. Returns nil if the series is too
  short to partition meaningfully (needs >= 32 points).

  Note on interpretation: R/S analysis has finite-sample bias that shifts
  absolute values of H upward. Empirically on 512-sample AR(1) processes:
  random walks produce H ≈ 0.98, mean-reverting series produce H ≈ 0.55-0.70.
  For regime filtering, a threshold around 0.7 (not the theoretical 0.5) is
  the right call.
  """
  def hurst_exponent(series) when is_list(series) and length(series) >= 32 do
    n = length(series)
    arr = Enum.with_index(series) |> Enum.map(fn {x, i} -> {i, x} end)

    # Use power-of-2 segment sizes up to n/2 for clean R/S aggregation
    segment_sizes =
      Stream.unfold(8, fn s -> if s * 2 <= n, do: {s, s * 2}, else: nil end)
      |> Enum.to_list()

    if length(segment_sizes) < 3 do
      # Not enough segment sizes for a meaningful regression
      nil
    else
      rs_points =
        Enum.map(segment_sizes, fn seg ->
          log_seg = :math.log(seg)
          log_rs = :math.log(mean_rs(arr, seg))
          {log_seg, log_rs}
        end)

      # Linear fit log(R/S) = H·log(n) + const → slope is Hurst
      xs = Enum.map(rs_points, &elem(&1, 0))
      ys = Enum.map(rs_points, &elem(&1, 1))

      case ols_simple(xs, ys) do
        {:ok, %{slope: h}} -> Float.round(h, 4)
        _ -> nil
      end
    end
  end

  def hurst_exponent(_), do: nil

  @doc """
  One-shot "is this pair worth trading?" check combining all three tests.

  Returns `{:ok, metrics}` if the spread passes cointegration (ADF) and
  half-life filter; `{:reject, reason}` otherwise.

  Options:
  - `:max_half_life` (default: 60) — reject pairs reverting slower than this
  - `:max_hurst` (default: nil = skip) — reject if Hurst >= this value
    (0.7 is empirically calibrated for R/S; use nil to disable Hurst gate)
  """
  def classify(spread_series, opts \\ []) do
    max_half_life = Keyword.get(opts, :max_half_life, 60)
    max_hurst = Keyword.get(opts, :max_hurst)

    cond do
      # Primary gate: ADF must show stationarity
      true ->
        case adf_test(spread_series) do
          %{stationary?: true} = adf ->
            case half_life(spread_series) do
              hl when is_number(hl) and hl <= max_half_life ->
                hurst = hurst_exponent(spread_series)

                if is_number(max_hurst) and is_number(hurst) and hurst >= max_hurst do
                  {:reject, {:hurst_too_high, hurst}}
                else
                  {:ok, %{adf: adf, half_life: hl, hurst: hurst}}
                end

              nil ->
                {:reject, :no_half_life}

              hl when hl > max_half_life ->
                {:reject, {:half_life_too_long, hl}}
            end

          _ ->
            {:reject, :non_stationary}
        end
    end
  end

  # ── Internal OLS + helpers ─────────────────────────────────

  # y_lag = series without last element; dy = first differences starting at index 1.
  # Both have length n-1 so they pair element-wise.
  defp build_lagged_and_diffed(series) do
    n = length(series)
    arr = List.to_tuple(series)

    y_lag = for i <- 0..(n - 2), do: elem(arr, i)
    dy = for i <- 1..(n - 1), do: elem(arr, i) - elem(arr, i - 1)

    {y_lag, dy}
  end

  # Closed-form OLS for y = α + β·x + ε.
  # Returns slope, intercept, and standard error of the slope.
  defp ols_simple(xs, ys) when length(xs) == length(ys) and length(xs) >= 3 do
    n = length(xs)
    mean_x = Enum.sum(xs) / n
    mean_y = Enum.sum(ys) / n

    {sxx, sxy} =
      Enum.zip(xs, ys)
      |> Enum.reduce({0.0, 0.0}, fn {x, y}, {sxx_acc, sxy_acc} ->
        dx = x - mean_x
        {sxx_acc + dx * dx, sxy_acc + dx * (y - mean_y)}
      end)

    if sxx == 0.0 do
      {:error, :zero_variance_x}
    else
      slope = sxy / sxx
      intercept = mean_y - slope * mean_x

      # Residual sum of squares
      rss =
        Enum.zip(xs, ys)
        |> Enum.reduce(0.0, fn {x, y}, acc ->
          pred = intercept + slope * x
          res = y - pred
          acc + res * res
        end)

      # Standard error of slope: sqrt(rss / (n-2) / sxx)
      residual_variance = rss / max(n - 2, 1)
      slope_se = :math.sqrt(residual_variance / sxx)

      {:ok, %{slope: slope, intercept: intercept, slope_se: slope_se}}
    end
  end

  defp ols_simple(_, _), do: {:error, :insufficient_data}

  # Mean R/S across equal-sized segments of the series.
  defp mean_rs(indexed, seg_size) do
    segments =
      indexed
      |> Enum.chunk_every(seg_size, seg_size, :discard)
      |> Enum.map(fn chunk -> Enum.map(chunk, &elem(&1, 1)) end)

    rs_values = Enum.map(segments, &rescaled_range/1)

    # Guard against log(0)
    case Enum.sum(rs_values) / max(length(rs_values), 1) do
      v when v > 0 -> v
      _ -> 1.0e-10
    end
  end

  # Rescaled range of a single segment: range(cumulative demeaned) / stddev
  defp rescaled_range(segment) do
    n = length(segment)
    mean = Enum.sum(segment) / n
    demeaned = Enum.map(segment, &(&1 - mean))

    # Cumulative sum
    {cum, _} =
      Enum.reduce(demeaned, {[], 0.0}, fn d, {acc, running} ->
        new = running + d
        {[new | acc], new}
      end)

    cum = Enum.reverse(cum)
    range = Enum.max(cum) - Enum.min(cum)

    variance = Enum.reduce(demeaned, 0.0, fn d, acc -> acc + d * d end) / n
    std = :math.sqrt(variance)

    if std == 0.0, do: 0.0, else: range / std
  end
end
