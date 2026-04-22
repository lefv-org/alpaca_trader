defmodule AlpacaTrader.Types.PositionTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.Types.Position

  test "market_value/1 = qty * mark" do
    p = %Position{venue: :alpaca, symbol: "AAPL", qty: Decimal.new("10"), mark: Decimal.new("150")}
    assert Decimal.equal?(Position.market_value(p), Decimal.new("1500"))
  end

  test "market_value/1 returns 0 when mark nil" do
    p = %Position{venue: :alpaca, symbol: "AAPL", qty: Decimal.new("10"), mark: nil}
    assert Decimal.equal?(Position.market_value(p), Decimal.new(0))
  end

  test "direction/1 returns :long | :short | :flat" do
    assert Position.direction(%Position{qty: Decimal.new("10")}) == :long
    assert Position.direction(%Position{qty: Decimal.new("-5")}) == :short
    assert Position.direction(%Position{qty: Decimal.new(0)}) == :flat
  end
end
