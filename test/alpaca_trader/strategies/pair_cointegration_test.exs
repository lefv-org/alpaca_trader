defmodule AlpacaTrader.Strategies.PairCointegrationTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.Strategies.PairCointegration

  test "id is :pair_cointegration" do
    assert PairCointegration.id() == :pair_cointegration
  end

  test "scan/2 returns empty list (placeholder)" do
    {:ok, state} = PairCointegration.init(%{})
    assert {:ok, [], ^state} = PairCointegration.scan(state, %{})
  end

  test "exits/2 returns empty list (placeholder)" do
    {:ok, state} = PairCointegration.init(%{})
    assert {:ok, [], ^state} = PairCointegration.exits(state, %{})
  end
end
