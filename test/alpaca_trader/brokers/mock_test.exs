defmodule AlpacaTrader.Brokers.MockTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.Brokers.Mock
  alias AlpacaTrader.Types.Order

  setup do
    Mock.reset()
    :ok
  end

  test "submit_order records submission and returns filled order" do
    order = Order.new(venue: :mock, symbol: "TEST", side: :buy, type: :market,
                      size: Decimal.new("10"), size_mode: :qty)
    assert {:ok, filled} = Mock.submit_order(order, [])
    assert filled.status == :filled
    [recorded] = Mock.submitted_orders()
    assert recorded.symbol == "TEST"
    assert recorded.side == :buy
  end

  test "put_account/1 overrides account returned by account/0" do
    Mock.put_account(%{equity: "100", buying_power: "200", cash: "150"})
    assert {:ok, acc} = Mock.account()
    assert Decimal.equal?(acc.equity, Decimal.new("100"))
    assert Decimal.equal?(acc.buying_power, Decimal.new("200"))
    assert Decimal.equal?(acc.cash, Decimal.new("150"))
  end

  test "put_positions/1 overrides positions" do
    alias AlpacaTrader.Types.Position
    p = %Position{venue: :mock, symbol: "X", qty: Decimal.new("1"), mark: Decimal.new("50")}
    Mock.put_positions([p])
    assert {:ok, [^p]} = Mock.positions()
  end

  test "put_next_submit_result/1 forces next submit to return a specific result" do
    Mock.put_next_submit_result({:error, :rate_limited})
    order = Order.new(venue: :mock, symbol: "Y", side: :buy, type: :market,
                      size: Decimal.new("1"), size_mode: :qty)
    assert {:error, :rate_limited} = Mock.submit_order(order, [])
  end

  test "capabilities reports shorting:true, perps:false, h24" do
    caps = Mock.capabilities()
    assert caps.shorting
    refute caps.perps
    assert caps.hours == :h24
  end
end
