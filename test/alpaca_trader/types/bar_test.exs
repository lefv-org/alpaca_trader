defmodule AlpacaTrader.Types.BarTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.Types.Bar

  test "bar holds OHLCV and venue" do
    bar = %Bar{venue: :alpaca, symbol: "AAPL",
               o: Decimal.new("100"), h: Decimal.new("105"),
               l: Decimal.new("99"), c: Decimal.new("104"),
               v: Decimal.new("1000"), ts: DateTime.utc_now()}
    assert bar.timeframe == :minute
  end
end
