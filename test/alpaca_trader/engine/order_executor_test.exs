defmodule AlpacaTrader.Engine.OrderExecutorTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.Engine.OrderExecutor

  describe "build_order/3" do
    test "market mode builds a market order (legacy default)" do
      order =
        OrderExecutor.build_order(
          %{symbol: "AAPL", qty: 10, side: :buy},
          %{bid: 99.0, ask: 101.0},
          mode: :market
        )

      assert order.type == "market"
      refute Map.has_key?(order, :limit_price)
    end

    test "marketable_limit mode sets limit_price at ask + k*spread on buy" do
      order =
        OrderExecutor.build_order(
          %{symbol: "AAPL", qty: 10, side: :buy},
          %{bid: 99.0, ask: 101.0},
          mode: :marketable_limit,
          spread_mult: 0.25
        )

      assert order.type == "limit"
      assert order.time_in_force == "ioc"
      # ask + 0.25 * spread (2.0) = 101.0 + 0.5 = 101.5
      assert_in_delta order.limit_price, 101.5, 1.0e-6
    end

    test "marketable_limit mode sets limit_price at bid - k*spread on sell" do
      order =
        OrderExecutor.build_order(
          %{symbol: "AAPL", qty: 10, side: :sell},
          %{bid: 99.0, ask: 101.0},
          mode: :marketable_limit,
          spread_mult: 0.25
        )

      assert order.type == "limit"
      # bid - 0.25 * spread = 99.0 - 0.5 = 98.5
      assert_in_delta order.limit_price, 98.5, 1.0e-6
    end
  end
end
