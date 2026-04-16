defmodule AlpacaTrader.Arbitrage.KalmanFilter do
  @moduledoc """
  One-dimensional Kalman filter for dynamic hedge ratio estimation in pairs
  trading.

  Observation model: price_a_t = beta_t * price_b_t + epsilon_t
  Transition model:  beta_t = beta_{t-1} + w_t   (random walk with variance Q)

  Kalman gives us the MMSE estimate of beta at each new observation, along
  with its variance. Unlike static OLS, beta adapts as the relationship
  between A and B drifts.

  Returns the full trace so the caller can inspect convergence, or just the
  final hedge ratio via `final_ratio/1`.

  Pure functional. Parameters:
  - `delta` (process noise, default 1.0e-5): how fast beta is allowed to drift
  - `r` (observation noise, default 1.0): confidence in observations
  - `init_beta` (default 1.0)
  - `init_p` (default 1.0): initial uncertainty on beta

  Sensible defaults are for minute-bar crypto; tune delta upward for faster
  drift (intraday rebalancing) or downward for slow drift (daily bars).
  """

  @default_delta 1.0e-5
  @default_r 1.0
  @default_init_beta 1.0
  @default_init_p 1.0

  @doc """
  Run the filter forward on paired price series. Returns `{beta_series, _}`
  where `beta_series` has one entry per observation.

  `opts`:
  - `:delta` — process noise (variance of beta drift per step)
  - `:r` — observation noise
  - `:init_beta`, `:init_p` — initial state
  """
  def run(prices_a, prices_b, opts \\ [])

  def run(prices_a, prices_b, _opts) when length(prices_a) != length(prices_b) do
    {:error, :length_mismatch}
  end

  def run([], [], _opts), do: {:ok, []}

  def run(prices_a, prices_b, opts) do
    delta = Keyword.get(opts, :delta, @default_delta)
    r = Keyword.get(opts, :r, @default_r)
    init_beta = Keyword.get(opts, :init_beta, @default_init_beta)
    init_p = Keyword.get(opts, :init_p, @default_init_p)

    {trace, _} =
      Enum.zip(prices_a, prices_b)
      |> Enum.reduce({[], {init_beta, init_p}}, fn {a, b}, {acc, {beta, p}} ->
        # Predict: beta stays the same, variance grows by delta
        p_pred = p + delta

        # Innovation: observed minus expected
        y_hat = beta * b
        innov = a - y_hat
        innov_var = b * p_pred * b + r

        # Kalman gain
        k = (p_pred * b) / innov_var

        # Update
        new_beta = beta + k * innov
        new_p = (1.0 - k * b) * p_pred

        {[{new_beta, new_p} | acc], {new_beta, new_p}}
      end)

    {:ok, Enum.reverse(trace)}
  end

  @doc """
  Run the filter and return just the final hedge ratio. Convenient when you
  don't need the trace.
  """
  def final_ratio(prices_a, prices_b, opts \\ []) do
    case run(prices_a, prices_b, opts) do
      {:ok, []} -> nil
      {:ok, trace} -> trace |> List.last() |> elem(0)
      {:error, _} -> nil
    end
  end
end
