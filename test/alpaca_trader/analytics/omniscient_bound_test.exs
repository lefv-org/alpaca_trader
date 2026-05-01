defmodule AlpacaTrader.Analytics.OmniscientBoundTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Analytics.OmniscientBound

  test "monotonic up series with zero costs returns gross movement" do
    closes = [100.0, 101.0, 102.0, 103.0]

    r =
      OmniscientBound.run(closes,
        spread_bps: 0.0,
        fee_bps: 0.0,
        notional: 100.0,
        long_only: true
      )

    # Three steps of +1 on $100 notional: gross +1 + +1*100/101 + +1*100/102.
    assert_in_delta r.pnl, 1.0 + 100.0 / 101.0 + 100.0 / 102.0, 1.0e-6
    assert r.trades == 3
    assert r.hit_rate == 1.0
  end

  test "long-only filters losses" do
    closes = [100.0, 99.0, 100.0]

    long = OmniscientBound.run(closes, spread_bps: 0.0, fee_bps: 0.0, long_only: true)
    sym = OmniscientBound.run(closes, spread_bps: 0.0, fee_bps: 0.0, long_only: false)

    assert long.trades == 1
    assert sym.trades == 2
    assert sym.pnl > long.pnl
  end

  test "high transaction cost zeroes out small edges" do
    # 10 bps moves with 100 bps cost ⇒ no profitable trades.
    closes = [100.0, 100.1, 100.0, 100.1]
    r = OmniscientBound.run(closes, spread_bps: 50.0, fee_bps: 50.0)
    assert r.trades == 0
    assert r.pnl == 0.0
  end

  test "efficiency clipping" do
    assert OmniscientBound.efficiency(5.0, 10.0) == 0.5
    assert OmniscientBound.efficiency(5.0, 0.0) == 0.0
    assert OmniscientBound.efficiency(-2.0, 10.0) == -0.2
  end

  test "empty / single-element input" do
    assert OmniscientBound.run([]).pnl == 0.0
    assert OmniscientBound.run([100.0]).pnl == 0.0
  end
end
