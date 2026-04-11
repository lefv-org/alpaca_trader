defmodule AlpacaTrader.PairPositionStoreTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.PairPositionStore
  alias AlpacaTrader.PairPositionStore.PairPosition

  setup do
    PairPositionStore.clear()
    :ok
  end

  defp open_test_position(overrides \\ %{}) do
    defaults = %{
      asset_a: "AAPL",
      asset_b: "MSFT",
      direction: :long_a_short_b,
      tier: 2,
      z_score: 2.3,
      hedge_ratio: 0.5
    }

    PairPositionStore.open_position(Map.merge(defaults, overrides))
  end

  test "starts empty" do
    assert PairPositionStore.open_count() == 0
  end

  test "open_position creates a tracked position" do
    {:ok, pos} = open_test_position()
    assert pos.asset_a == "AAPL"
    assert pos.asset_b == "MSFT"
    assert pos.status == :open
    assert pos.bars_held == 0
    assert pos.exit_z_threshold == 0.5
    assert pos.stop_z_threshold == 4.0
    assert pos.max_hold_bars == 20
  end

  test "tier 3 positions get wider thresholds" do
    {:ok, pos} = open_test_position(%{tier: 3})
    assert pos.exit_z_threshold == 0.75
    assert pos.stop_z_threshold == 5.0
    assert pos.max_hold_bars == 30
  end

  test "find_open_for_asset finds by either leg" do
    {:ok, _} = open_test_position()
    assert %PairPosition{} = PairPositionStore.find_open_for_asset("AAPL")
    assert %PairPosition{} = PairPositionStore.find_open_for_asset("MSFT")
    assert PairPositionStore.find_open_for_asset("GOOG") == nil
  end

  test "tick increments bars_held and updates z-score" do
    {:ok, pos} = open_test_position()
    {:ok, updated} = PairPositionStore.tick(pos.id, 1.5)
    assert updated.bars_held == 1
    assert updated.current_z_score == 1.5

    {:ok, updated2} = PairPositionStore.tick(pos.id, 0.8)
    assert updated2.bars_held == 2
    assert updated2.current_z_score == 0.8
  end

  test "close_position marks as closed" do
    {:ok, pos} = open_test_position()
    {:ok, closed} = PairPositionStore.close_position(pos.id)
    assert closed.status == :closed
    assert PairPositionStore.find_open_for_asset("AAPL") == nil
  end

  test "open_positions returns only open" do
    {:ok, pos1} = open_test_position()
    {:ok, _pos2} = open_test_position(%{asset_a: "NVDA", asset_b: "AMD"})
    assert PairPositionStore.open_count() == 2

    PairPositionStore.close_position(pos1.id)
    assert PairPositionStore.open_count() == 1
  end

  test "clear removes all positions" do
    {:ok, _} = open_test_position()
    PairPositionStore.clear()
    assert PairPositionStore.open_count() == 0
  end
end
