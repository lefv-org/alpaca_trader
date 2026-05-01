defmodule AlpacaTrader.Analytics.PerformanceTrackerTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.Analytics.PerformanceTracker

  setup do
    # The tracker is started by the application; if it isn't (test env), start
    # it here. Reset state by re-creating the table.
    case Process.whereis(PerformanceTracker) do
      nil ->
        {:ok, _pid} = PerformanceTracker.start_link([])

      _pid ->
        :ok
    end

    :ets.delete_all_objects(:performance_tracker)
    :ok
  end

  test "record_pnl accumulates and snapshot returns totals" do
    PerformanceTracker.record_pnl(:test_strat, 1.5)
    PerformanceTracker.record_pnl(:test_strat, -0.5)
    PerformanceTracker.record_pnl(:test_strat, 2.0)

    # Cast so wait briefly.
    Process.sleep(20)
    snap = PerformanceTracker.snapshot(:test_strat)
    assert snap.points == 3
    assert_in_delta snap.pnl_total, 3.0, 1.0e-6
  end

  test "sharpe positive for steady-positive returns" do
    for x <- [0.5, 0.6, 0.55, 0.58, 0.62, 0.5, 0.59], do: PerformanceTracker.record_pnl(:winner, x)
    Process.sleep(20)
    s = PerformanceTracker.sharpe(:winner)
    assert is_float(s)
    assert s > 0.0
  end

  test "persistence flat zeroes near zero" do
    for x <- [0.0, 0.0, 0.0, 0.0], do: PerformanceTracker.record_pnl(:flat, x)
    Process.sleep(20)
    p = PerformanceTracker.persistence(:flat)
    assert is_nil(p)
  end

  test "aggressive ratio counts market vs limit" do
    PerformanceTracker.record_fill(:rt, :buy, :market)
    PerformanceTracker.record_fill(:rt, :sell, :market)
    PerformanceTracker.record_fill(:rt, :buy, :limit)
    Process.sleep(20)
    ratio = PerformanceTracker.aggressive_ratio(:rt)
    assert_in_delta ratio, 2.0 / 3.0, 1.0e-6
  end

  test "snapshot for unknown strategy returns zero points" do
    snap = PerformanceTracker.snapshot(:never_traded)
    assert snap.points == 0
  end
end
