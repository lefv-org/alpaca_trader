defmodule AlpacaTrader.Types.AccountTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.Types.Account

  test "builds account with required fields" do
    acc = %Account{venue: :alpaca, equity: Decimal.new("100"),
                   cash: Decimal.new("80"), buying_power: Decimal.new("160")}
    assert acc.venue == :alpaca
    assert acc.daytrade_count == 0
    assert acc.pattern_day_trader == false
    assert acc.currency == "USD"
  end
end
