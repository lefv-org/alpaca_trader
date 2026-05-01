defmodule AlpacaTrader.Fees.TradingValueTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Fees.TradingValue

  test "default taker bps applied to notional" do
    fill = %{venue: :alpaca, symbol: "AAPL", side: :buy_taker, qty: 10.0, price: 200.0}
    fee = TradingValue.compute_fee(fill)
    # 25 bps of $2000 = $5
    assert Decimal.equal?(Decimal.round(fee, 4), Decimal.new("5.0000"))
  end

  test "maker bps lower than taker by default" do
    fill = %{venue: :alpaca, symbol: "AAPL", side: :buy_maker, qty: 10.0, price: 200.0}
    fee = TradingValue.compute_fee(fill)
    # 15 bps of $2000 = $3
    assert Decimal.equal?(Decimal.round(fee, 4), Decimal.new("3.0000"))
  end

  test "opts override defaults" do
    fill = %{venue: :alpaca, symbol: "AAPL", side: :sell_taker, qty: 1.0, price: 100.0}
    fee = TradingValue.compute_fee(fill, taker_bps: 100.0)
    # 100 bps of $100 = $1
    assert Decimal.equal?(Decimal.round(fee, 4), Decimal.new("1.0000"))
  end
end
