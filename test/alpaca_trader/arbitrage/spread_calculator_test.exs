defmodule AlpacaTrader.Arbitrage.SpreadCalculatorTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Arbitrage.SpreadCalculator

  describe "hedge_ratio/2" do
    test "returns 1.0 for identical series" do
      prices = [100.0, 101.0, 102.0, 103.0, 104.0]
      assert_in_delta SpreadCalculator.hedge_ratio(prices, prices), 1.0, 0.001
    end

    test "returns 2.0 when A is exactly 2x B" do
      a = [200.0, 202.0, 204.0, 206.0, 208.0]
      b = [100.0, 101.0, 102.0, 103.0, 104.0]
      assert_in_delta SpreadCalculator.hedge_ratio(a, b), 2.0, 0.001
    end

    test "returns 0.5 when A is exactly 0.5x B" do
      b = [100.0, 102.0, 104.0, 106.0, 108.0]
      a = [50.0, 51.0, 52.0, 53.0, 54.0]
      assert_in_delta SpreadCalculator.hedge_ratio(a, b), 0.5, 0.001
    end

    test "returns 0.0 when B has zero variance" do
      a = [100.0, 101.0, 102.0]
      b = [50.0, 50.0, 50.0]
      assert SpreadCalculator.hedge_ratio(a, b) == 0.0
    end

    test "raises ArgumentError with fewer than 2 data points" do
      assert_raise ArgumentError, fn ->
        SpreadCalculator.hedge_ratio([1.0], [2.0])
      end
    end

    test "handles negative correlation" do
      a = [100.0, 99.0, 98.0, 97.0, 96.0]
      b = [50.0, 51.0, 52.0, 53.0, 54.0]
      ratio = SpreadCalculator.hedge_ratio(a, b)
      assert ratio < 0
      assert_in_delta ratio, -1.0, 0.001
    end
  end

  describe "spread_series/3" do
    test "returns zeros when ratio is 1.0 and series are identical" do
      prices = [100.0, 101.0, 102.0]
      spread = SpreadCalculator.spread_series(prices, prices, 1.0)
      assert Enum.all?(spread, fn x -> abs(x) < 1.0e-10 end)
    end

    test "computes correct spread with known values" do
      a = [10.0, 20.0, 30.0]
      b = [5.0, 10.0, 15.0]
      spread = SpreadCalculator.spread_series(a, b, 2.0)
      # 10 - 2*5 = 0, 20 - 2*10 = 0, 30 - 2*15 = 0
      assert spread == [0.0, 0.0, 0.0]
    end

    test "computes correct spread with ratio 1.5" do
      a = [100.0, 110.0, 120.0]
      b = [60.0, 70.0, 80.0]
      spread = SpreadCalculator.spread_series(a, b, 1.5)
      # 100 - 1.5*60 = 10, 110 - 1.5*70 = 5, 120 - 1.5*80 = 0
      assert_in_delta Enum.at(spread, 0), 10.0, 0.001
      assert_in_delta Enum.at(spread, 1), 5.0, 0.001
      assert_in_delta Enum.at(spread, 2), 0.0, 0.001
    end

    test "returns empty list for empty inputs" do
      assert SpreadCalculator.spread_series([], [], 1.0) == []
    end
  end

  describe "z_score/1" do
    test "returns 0.0 for constant series" do
      assert SpreadCalculator.z_score([5.0, 5.0, 5.0]) == 0.0
    end

    test "returns positive z for last value above mean" do
      spread = [0.0, 0.0, 0.0, 0.0, 10.0]
      assert SpreadCalculator.z_score(spread) > 0
    end

    test "returns negative z for last value below mean" do
      spread = [10.0, 10.0, 10.0, 10.0, 0.0]
      assert SpreadCalculator.z_score(spread) < 0
    end

    test "returns 0.0 for fewer than 2 elements" do
      assert SpreadCalculator.z_score([5.0]) == 0.0
    end

    test "returns 0.0 for empty list" do
      assert SpreadCalculator.z_score([]) == 0.0
    end

    test "computes correct z-score with known data" do
      # Series: [2, 4, 4, 4, 5, 5, 7, 9]
      # mean = 5.0, variance = 4.0, std = 2.0
      # last = 9, z = (9 - 5) / 2 = 2.0
      spread = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]
      assert_in_delta SpreadCalculator.z_score(spread), 2.0, 0.001
    end

    test "returns correct z-score when last value equals mean" do
      # [1, 2, 3] -> mean=2, std=sqrt(2/3), z = (3-2)/sqrt(2/3) ... but last=3
      # Let's use [0, 5, 10, 5] -> mean=5, last=5, z=0
      assert_in_delta SpreadCalculator.z_score([0.0, 5.0, 10.0, 5.0]), 0.0, 0.001
    end
  end

  describe "analyze/2" do
    test "returns nil for fewer than 20 data points" do
      assert SpreadCalculator.analyze(Enum.to_list(1..19), Enum.to_list(1..19)) == nil
    end

    test "returns nil for mismatched lengths" do
      assert SpreadCalculator.analyze(Enum.to_list(1..20), Enum.to_list(1..25)) == nil
    end

    test "returns nil when first series is too short" do
      a = Enum.map(1..10, &(&1 * 1.0))
      b = Enum.map(1..20, &(&1 * 1.0))
      assert SpreadCalculator.analyze(a, b) == nil
    end

    test "returns map with all required keys for valid data" do
      # Use deterministic data: A = 2*B + small offset
      a = Enum.map(1..60, fn i -> 100.0 + i * 0.5 end)
      b = Enum.map(1..60, fn i -> 50.0 + i * 0.25 end)
      result = SpreadCalculator.analyze(a, b)

      assert is_map(result)
      assert Map.has_key?(result, :hedge_ratio)
      assert Map.has_key?(result, :z_score)
      assert Map.has_key?(result, :mean)
      assert Map.has_key?(result, :std)
      assert Map.has_key?(result, :current_spread)
    end

    test "returns correct hedge ratio for perfectly correlated series" do
      # A = 2*B exactly => hedge_ratio should be 2.0
      b = Enum.map(1..30, fn i -> 50.0 + i * 1.0 end)
      a = Enum.map(b, fn x -> 2.0 * x end)
      result = SpreadCalculator.analyze(a, b)

      assert_in_delta result.hedge_ratio, 2.0, 0.001
    end

    test "spread is zero when A = ratio * B exactly" do
      b = Enum.map(1..30, fn i -> 50.0 + i * 1.0 end)
      a = Enum.map(b, fn x -> 2.0 * x end)
      result = SpreadCalculator.analyze(a, b)

      # When A = 2*B exactly, spread = A - 2*B = 0 everywhere
      assert_in_delta result.current_spread, 0.0, 0.001
      assert_in_delta result.std, 0.0, 0.001
      assert_in_delta result.z_score, 0.0, 0.001
    end

    test "all returned values are floats" do
      a = Enum.map(1..30, fn i -> 100.0 + i * 0.5 end)
      b = Enum.map(1..30, fn i -> 50.0 + i * 0.25 end)
      result = SpreadCalculator.analyze(a, b)

      assert is_float(result.hedge_ratio)
      assert is_float(result.z_score)
      assert is_float(result.mean)
      assert is_float(result.std)
      assert is_float(result.current_spread)
    end
  end
end
