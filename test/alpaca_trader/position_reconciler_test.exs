defmodule AlpacaTrader.PositionReconcilerTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.PositionReconciler

  describe "orphan?/1 with crypto symbol normalisation" do
    setup do
      :persistent_term.put({PositionReconciler, :orphan_symbols}, MapSet.new(["ETHUSD"]))
      on_exit(fn -> :persistent_term.put({PositionReconciler, :orphan_symbols}, MapSet.new()) end)
      :ok
    end

    test "matches with-slash query against no-slash orphan entry" do
      # Alpaca returns ETHUSD; engine queries ETH/USD. They must compare equal
      # so the orphan-blocked entry path doesn't permanently block crypto trades.
      assert PositionReconciler.orphan?("ETH/USD")
      assert PositionReconciler.orphan?("ETHUSD")
    end

    test "non-orphan symbol returns false" do
      refute PositionReconciler.orphan?("AAPL")
    end
  end
end
