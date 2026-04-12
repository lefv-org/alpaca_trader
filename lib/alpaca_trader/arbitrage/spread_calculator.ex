defmodule AlpacaTrader.Arbitrage.SpreadCalculator do
  @moduledoc """
  OLS hedge ratio and z-score calculations for pairs trading.

  Pure functional module — no GenServers, no ETS, no external dependencies.
  All functions operate on lists of floats and return deterministic results.
  """

  @doc """
  Compute OLS hedge ratio: beta where prices_a ≈ alpha + beta * prices_b.
  Uses: beta = cov(a,b) / var(b)

  Raises `ArgumentError` if fewer than 2 data points are provided.
  Returns 0.0 if B has zero variance.
  """
  def hedge_ratio(prices_a, prices_b) when length(prices_a) == length(prices_b) do
    n = length(prices_a)
    if n < 2, do: raise(ArgumentError, "need at least 2 data points")

    mean_a = Enum.sum(prices_a) / n
    mean_b = Enum.sum(prices_b) / n

    cov =
      Enum.zip(prices_a, prices_b)
      |> Enum.map(fn {a, b} -> (a - mean_a) * (b - mean_b) end)
      |> Enum.sum()
      |> Kernel./(n)

    var_b =
      prices_b
      |> Enum.map(fn b -> (b - mean_b) * (b - mean_b) end)
      |> Enum.sum()
      |> Kernel./(n)

    if var_b == 0, do: 0.0, else: cov / var_b
  end

  @doc """
  Compute spread series: spread_i = price_a_i - ratio * price_b_i
  """
  def spread_series(prices_a, prices_b, ratio) do
    Enum.zip_with(prices_a, prices_b, fn a, b -> a - ratio * b end)
  end

  @doc """
  Compute z-score of the last value in a spread series.
  z = (last - mean) / std

  Returns 0.0 if std is 0 or fewer than 2 elements are provided.
  """
  def z_score(spread) when length(spread) < 2, do: 0.0

  def z_score(spread) do
    n = length(spread)
    mean = Enum.sum(spread) / n

    variance =
      Enum.map(spread, fn x -> (x - mean) * (x - mean) end)
      |> Enum.sum()
      |> Kernel./(n)

    std = :math.sqrt(variance)

    if std == 0.0, do: 0.0, else: (List.last(spread) - mean) / std
  end

  @doc """
  Full analysis: compute hedge ratio, spread series, and z-score.

  Returns nil if:
  - fewer than 20 data points in either series
  - series lengths do not match

  Returns a map with keys:
  - `:hedge_ratio` — OLS beta
  - `:z_score` — z-score of the current (last) spread value
  - `:mean` — mean of the spread series
  - `:std` — standard deviation of the spread series
  - `:current_spread` — last value in the spread series
  """
  def analyze(prices_a, prices_b)
      when length(prices_a) < 20 or length(prices_b) < 20,
      do: nil

  def analyze(prices_a, prices_b)
      when length(prices_a) != length(prices_b),
      do: nil

  def analyze(prices_a, prices_b) do
    ratio = hedge_ratio(prices_a, prices_b)
    spread = spread_series(prices_a, prices_b, ratio)
    z = z_score(spread)
    n = length(spread)
    mean = Enum.sum(spread) / n

    variance =
      Enum.map(spread, fn x -> (x - mean) * (x - mean) end)
      |> Enum.sum()
      |> Kernel./(n)

    std = :math.sqrt(variance)

    %{
      hedge_ratio: Float.round(ratio, 6),
      z_score: Float.round(z, 4),
      mean: Float.round(mean, 4),
      std: Float.round(std, 4),
      current_spread: Float.round(List.last(spread), 4)
    }
  end

  @doc """
  Trend strength of a spread series (efficiency ratio, 0-100).
  > 25 = trending (safe to flip), < 20 = choppy (don't flip).
  """
  def trend_strength(spread) when length(spread) < 10, do: 0.0

  def trend_strength(spread) do
    changes =
      spread
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)

    if changes == [] do
      0.0
    else
      net_move = abs(Enum.sum(changes))
      total_move = Enum.map(changes, &abs/1) |> Enum.sum()

      if total_move == 0,
        do: 0.0,
        else: Float.round(net_move / total_move * 100, 1)
    end
  end
end
