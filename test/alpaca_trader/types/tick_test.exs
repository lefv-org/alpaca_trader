defmodule AlpacaTrader.Types.TickTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.Types.Tick

  test "tick holds bid/ask/last" do
    tick = %Tick{venue: :hyperliquid, symbol: "BTC",
                 bid: Decimal.new("60000"), ask: Decimal.new("60010"),
                 last: Decimal.new("60005"), ts: DateTime.utc_now()}
    assert tick.venue == :hyperliquid
    assert Decimal.equal?(tick.last, Decimal.new("60005"))
  end
end
