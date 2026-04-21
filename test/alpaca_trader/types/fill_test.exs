defmodule AlpacaTrader.Types.FillTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.Types.Fill

  test "fill carries order_id, qty, price, fee default 0" do
    fill = %Fill{order_id: "abc", venue: :alpaca, symbol: "AAPL",
                 side: :buy, qty: Decimal.new("10"), price: Decimal.new("150"),
                 ts: DateTime.utc_now()}
    assert Decimal.equal?(fill.fee, Decimal.new(0))
    assert fill.side == :buy
  end
end
