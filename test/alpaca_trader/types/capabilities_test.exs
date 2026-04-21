defmodule AlpacaTrader.Types.CapabilitiesTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.Types.Capabilities

  test "new/1 builds with defaults" do
    caps = Capabilities.new()
    assert caps.shorting == false
    assert caps.perps == false
    assert caps.fractional == false
    assert caps.hours == :rth
    assert Decimal.equal?(caps.min_notional, Decimal.new(1))
    assert caps.fee_bps == 0
  end

  test "new/1 overrides" do
    caps = Capabilities.new(shorting: true, perps: true, hours: :h24, fee_bps: 5)
    assert caps.shorting
    assert caps.perps
    assert caps.hours == :h24
    assert caps.fee_bps == 5
  end
end
