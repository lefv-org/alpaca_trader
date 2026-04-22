defmodule AlpacaTrader.Types.FeedSpecTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.Types.FeedSpec

  test "builds with defaults" do
    spec = %FeedSpec{venue: :alpaca}
    assert spec.symbols == :whitelist
    assert spec.cadence == :minute
  end

  test "accepts explicit symbol list + cadence" do
    spec = %FeedSpec{venue: :hyperliquid, symbols: ["BTC", "ETH"], cadence: :second}
    assert spec.symbols == ["BTC", "ETH"]
    assert spec.cadence == :second
  end
end
