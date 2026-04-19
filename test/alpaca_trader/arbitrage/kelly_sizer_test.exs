defmodule AlpacaTrader.Arbitrage.KellySizerTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Arbitrage.KellySizer

  describe "kelly_fraction/3" do
    test "returns 0 when edge is non-positive" do
      # Equal wins and losses, 50% win rate → f* = 0
      assert KellySizer.kelly_fraction(0.5, 0.01, 0.01) == 0.0
    end

    test "returns positive fraction for favorable edge" do
      # 60% wins of 2%, 40% losses of 1% → f* = (0.6 * 2 - 0.4) / 2 = 0.4
      f = KellySizer.kelly_fraction(0.6, 0.02, 0.01)
      assert_in_delta f, 0.4, 1.0e-6
    end

    test "returns 0 if avg_loss is non-positive (no downside)" do
      assert KellySizer.kelly_fraction(0.6, 0.02, 0.0) == 0.0
    end

    test "returns 0 for edge-case win_rate outside (0,1)" do
      assert KellySizer.kelly_fraction(0.0, 0.02, 0.01) == 0.0
      assert KellySizer.kelly_fraction(1.0, 0.02, 0.01) == 0.0
    end
  end

  describe "size_cap/3" do
    test "applies fractional Kelly and caps at max_cap_pct" do
      equity = 10_000.0
      # Full Kelly = 0.4, half-Kelly = 0.2 → 20% = $2000 → capped at 10% = $1000
      cap =
        KellySizer.size_cap(equity, %{win_rate: 0.6, avg_win_pct: 0.02, avg_loss_pct: 0.01},
          fraction: 0.5,
          max_cap_pct: 0.10
        )

      assert cap == 1_000.0
    end

    test "returns equity * max_cap when stats missing" do
      cap = KellySizer.size_cap(10_000.0, %{}, fraction: 0.5, max_cap_pct: 0.05)
      assert cap == 500.0
    end
  end
end
