defmodule AlpacaTrader.Types.OrderTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.Types.Order

  test "new/1 requires venue, symbol, side, size" do
    order = Order.new(venue: :alpaca, symbol: "AAPL", side: :buy, size: Decimal.new("10"),
                      size_mode: :qty, type: :market)
    assert order.status == :pending
    assert order.id == nil
    assert order.venue == :alpaca
    assert order.side == :buy
  end

  test "new/1 raises on bad side" do
    assert_raise ArgumentError, fn ->
      Order.new(venue: :alpaca, symbol: "AAPL", side: :wrong, size: Decimal.new("1"),
                size_mode: :qty, type: :market)
    end
  end
end
