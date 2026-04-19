defmodule AlpacaTrader.RegimeDetectorTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.RegimeDetector

  describe "realized_vol_annualized/2" do
    test "computes annualized stdev of log returns (hourly bars, 24h/day * 252d)" do
      # Flat series has zero vol
      flat = List.duplicate(100.0, 100)
      assert RegimeDetector.realized_vol_annualized(flat, :hourly) == 0.0

      # Synthetic series with known daily log-return stdev ~ 0.01
      # annualized ≈ 0.01 * sqrt(252) ≈ 0.159
      rng = :rand.seed(:exsss, {1, 2, 3})
      series = generate_gbm_series(1000, 0.0001, 0.01 / :math.sqrt(24))
      _ = rng
      v = RegimeDetector.realized_vol_annualized(series, :hourly)
      assert v > 0.10 and v < 0.25
    end

    test "returns nil for series shorter than 20 bars" do
      assert RegimeDetector.realized_vol_annualized([1.0, 2.0, 3.0], :hourly) == nil
    end

    defp generate_gbm_series(n, drift, vol) do
      Enum.scan(1..n, 100.0, fn _, last ->
        z = :rand.normal()
        last * :math.exp(drift + vol * z)
      end)
    end
  end

  describe "allow_entry?/2" do
    test "allows when filter is disabled" do
      opts = [enabled: false, max_realized_vol: 0.3, max_adf_pvalue: 0.05]
      assert RegimeDetector.allow_entry?(%{spread: [], symbol_a_closes: []}, opts) == :ok
    end

    test "blocks when realized vol exceeds max" do
      opts = [enabled: true, max_realized_vol: 0.1]

      high_vol = Enum.map(1..200, fn i -> 100.0 + 10.0 * :math.sin(i / 3.0) end)
      inputs = %{spread: high_vol, symbol_a_closes: high_vol}
      assert {:blocked, {:realized_vol_too_high, _}} = RegimeDetector.allow_entry?(inputs, opts)
    end

    test "blocks when spread ADF shows non-stationarity (random walk)" do
      opts = [enabled: true, max_realized_vol: 10.0, max_adf_pvalue: 0.05]

      rw = Enum.scan(1..500, 0.0, fn _, acc -> acc + :rand.normal() end)
      flat_prices = List.duplicate(100.0, 500)

      assert {:blocked, {:spread_not_stationary, _}} =
               RegimeDetector.allow_entry?(
                 %{spread: rw, symbol_a_closes: flat_prices},
                 opts
               )
    end

    test "allows when both vol is low and spread is stationary" do
      opts = [enabled: true, max_realized_vol: 10.0, max_adf_pvalue: 0.05]

      stationary =
        Enum.scan(1..500, 0.0, fn _, last -> 0.3 * last + :rand.normal() end)

      flat_prices = List.duplicate(100.0, 500)

      assert :ok =
               RegimeDetector.allow_entry?(
                 %{spread: stationary, symbol_a_closes: flat_prices},
                 opts
               )
    end
  end
end
