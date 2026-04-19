defmodule AlpacaTrader.Arbitrage.MeanReversionTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Arbitrage.MeanReversion

  # ── helpers to synthesize known series ───────────────────────

  # AR(1): y_t = rho * y_{t-1} + epsilon_t, epsilon_t ~ N(0, 1)
  defp ar1_series(n, rho, seed \\ 42) do
    :rand.seed(:exsplus, {seed, seed + 1, seed + 2})

    Enum.reduce(1..n, [0.0], fn _, [y | _] = acc ->
      eps = :rand.normal()
      [rho * y + eps | acc]
    end)
    |> Enum.reverse()
  end

  # Random walk: y_t = y_{t-1} + epsilon_t (rho=1, non-stationary)
  defp random_walk(n, seed \\ 42), do: ar1_series(n, 1.0, seed)

  describe "adf_test/1" do
    test "accepts a strongly mean-reverting AR(1) series as stationary" do
      # rho = 0.5 → gamma = -0.5, clearly mean-reverting
      series = ar1_series(200, 0.5)
      result = MeanReversion.adf_test(series)

      assert %{stationary?: true, t_stat: t} = result
      assert t < -2.86, "expected t-stat < -2.86, got #{t}"
    end

    test "rejects a random walk as non-stationary" do
      series = random_walk(200)
      result = MeanReversion.adf_test(series)

      refute result.stationary?
    end

    test "returns nil for series shorter than 30 points" do
      assert MeanReversion.adf_test(Enum.to_list(1..10) |> Enum.map(&(&1 * 1.0))) == nil
    end
  end

  describe "half_life/1" do
    test "computes a sensible half-life for moderately mean-reverting series" do
      # rho = 0.8 → gamma = -0.2 → half_life = -ln(2)/ln(0.8) ≈ 3.1 bars
      series = ar1_series(200, 0.8)
      hl = MeanReversion.half_life(series)

      assert is_number(hl)
      assert hl > 1.0 and hl < 20.0
    end

    test "random walk either returns nil or a long half-life (ADF is the real gate)" do
      # Finite samples of random walks can accidentally look mildly reverting;
      # the definitive "don't trade" signal is ADF non-stationarity, not half-life.
      series = random_walk(300)

      case MeanReversion.half_life(series) do
        nil -> assert true
        hl when is_number(hl) -> assert hl > 5.0
      end
    end

    test "returns nil for too-short series" do
      assert MeanReversion.half_life([1.0, 2.0, 3.0]) == nil
    end
  end

  describe "hurst_exponent/1" do
    # Due to finite-sample R/S bias, absolute H values skew high.
    # What matters for a regime filter is the ORDERING across regimes.
    test "produces correct ordering: mean-reverting < random walk" do
      rw = random_walk(512) |> MeanReversion.hurst_exponent()
      strong = ar1_series(512, 0.2) |> MeanReversion.hurst_exponent()
      mild = ar1_series(512, 0.8) |> MeanReversion.hurst_exponent()

      assert is_number(rw) and is_number(strong) and is_number(mild)

      assert strong < mild,
             "stronger reversion should give lower H (got strong=#{strong} mild=#{mild})"

      assert mild < rw,
             "random walk should give higher H than mean-reverting (got rw=#{rw} mild=#{mild})"
    end

    test "returns nil for too-short series" do
      assert MeanReversion.hurst_exponent(Enum.to_list(1..20) |> Enum.map(&(&1 * 1.0))) == nil
    end
  end

  describe "classify/2" do
    test "accepts a clean mean-reverting spread" do
      series = ar1_series(200, 0.5)
      assert {:ok, metrics} = MeanReversion.classify(series, max_half_life: 60)
      assert metrics.adf.stationary?
      assert metrics.half_life > 0
    end

    test "rejects a random walk" do
      series = random_walk(200)
      assert {:reject, :non_stationary} = MeanReversion.classify(series)
    end

    test "rejects a stationary but slowly reverting spread when max_half_life is tight" do
      # rho = 0.98 → very slow reversion
      series = ar1_series(300, 0.98)
      assert {:reject, reason} = MeanReversion.classify(series, max_half_life: 5)
      assert match?({:half_life_too_long, _}, reason) or reason == :non_stationary
    end
  end
end
