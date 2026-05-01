defmodule AlpacaTrader.Fees.AsymmetricTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Fees.Asymmetric

  test "buy and sell can charge different rates" do
    fill_buy = %{venue: :alpaca, symbol: "BTC/USD", side: :buy_taker, qty: 1.0, price: 60_000.0}
    fill_sell = %{fill_buy | side: :sell_taker}

    fee_buy = Asymmetric.compute_fee(fill_buy, buy_taker_bps: 30.0, sell_taker_bps: 10.0)
    fee_sell = Asymmetric.compute_fee(fill_sell, buy_taker_bps: 30.0, sell_taker_bps: 10.0)

    # 30 bps of $60k = $180; 10 bps of $60k = $60
    assert Decimal.equal?(Decimal.round(fee_buy, 4), Decimal.new("180.0000"))
    assert Decimal.equal?(Decimal.round(fee_sell, 4), Decimal.new("60.0000"))
  end
end
