defmodule AlpacaTrader.Arbitrage.HalfLifeManagerTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Arbitrage.HalfLifeManager

  describe "time_stop_bars/3" do
    test "returns k * half_life rounded up" do
      assert HalfLifeManager.time_stop_bars(10.0, 2.0) == 20
      assert HalfLifeManager.time_stop_bars(7.3, 2.0) == 15
    end

    test "clamps to fallback when half_life is nil" do
      assert HalfLifeManager.time_stop_bars(nil, 2.0, fallback_bars: 60) == 60
    end

    test "falls back when half_life is non-positive" do
      assert HalfLifeManager.time_stop_bars(0.0, 2.0, fallback_bars: 42) == 42
      assert HalfLifeManager.time_stop_bars(-5.0, 2.0, fallback_bars: 42) == 42
    end

    test "default fallback is 60 when half_life is nil and no opts" do
      assert HalfLifeManager.time_stop_bars(nil, 2.0) == 60
    end
  end

  describe "size_multiplier/2" do
    test "returns 1.0 when half_life equals reference" do
      assert HalfLifeManager.size_multiplier(10.0, reference_half_life: 10.0) == 1.0
    end

    test "returns > 1.0 for faster reversion (shorter half-life)" do
      m = HalfLifeManager.size_multiplier(5.0, reference_half_life: 10.0)
      assert m > 1.0
    end

    test "returns < 1.0 for slower reversion" do
      m = HalfLifeManager.size_multiplier(20.0, reference_half_life: 10.0)
      assert m < 1.0
    end

    test "clamps to [min_mult, max_mult]" do
      m =
        HalfLifeManager.size_multiplier(1.0,
          reference_half_life: 10.0,
          min_mult: 0.5,
          max_mult: 2.0
        )

      assert m == 2.0

      m2 =
        HalfLifeManager.size_multiplier(100.0,
          reference_half_life: 10.0,
          min_mult: 0.5,
          max_mult: 2.0
        )

      assert m2 == 0.5
    end

    test "returns 1.0 when half_life is nil or non-positive" do
      assert HalfLifeManager.size_multiplier(nil) == 1.0
      assert HalfLifeManager.size_multiplier(0.0) == 1.0
      assert HalfLifeManager.size_multiplier(-3.0) == 1.0
    end
  end

  describe "should_time_stop?/2" do
    test "false before time_stop_bars" do
      refute HalfLifeManager.should_time_stop?(10, half_life: 10.0, multiplier: 2.0)
    end

    test "true at or past time_stop_bars" do
      assert HalfLifeManager.should_time_stop?(20, half_life: 10.0, multiplier: 2.0)
      assert HalfLifeManager.should_time_stop?(25, half_life: 10.0, multiplier: 2.0)
    end

    test "uses fallback when half_life is nil" do
      # With fallback 30, hold_bars 30 triggers stop
      assert HalfLifeManager.should_time_stop?(30, half_life: nil, fallback_bars: 30)
      refute HalfLifeManager.should_time_stop?(29, half_life: nil, fallback_bars: 30)
    end
  end
end
