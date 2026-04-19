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

  describe "resolve_time_in_force/3" do
    setup do
      original = Application.get_env(:alpaca_trader, :order_type_mode, :market)

      on_exit(fn ->
        Application.put_env(:alpaca_trader, :order_type_mode, original)
      end)

      :ok
    end

    test "forces IOC when marketable_limit mode produced a limit order" do
      Application.put_env(:alpaca_trader, :order_type_mode, :marketable_limit)

      # params["type"] is not set — it was resolved to "limit" by the mode.
      assert OrderExecutor.resolve_time_in_force("limit", %{}, "us_equity") == "ioc"
      assert OrderExecutor.resolve_time_in_force("limit", %{}, "crypto") == "ioc"
    end

    test "leaves non-limit orders with asset-class default in marketable_limit mode" do
      Application.put_env(:alpaca_trader, :order_type_mode, :marketable_limit)

      # Fallback to "market" when quotes aren't available shouldn't get IOC.
      assert OrderExecutor.resolve_time_in_force("market", %{}, "us_equity") == "day"
      assert OrderExecutor.resolve_time_in_force("market", %{}, "crypto") == "gtc"
    end

    test "respects explicit params time_in_force when caller set type" do
      Application.put_env(:alpaca_trader, :order_type_mode, :marketable_limit)

      # Caller explicitly set type=limit (e.g., stop-limit exit) — honor their TIF.
      params = %{"type" => "limit", "time_in_force" => "gtc"}
      assert OrderExecutor.resolve_time_in_force("limit", params, "us_equity") == "gtc"
    end

    test "uses asset-class default when mode is :market" do
      Application.put_env(:alpaca_trader, :order_type_mode, :market)

      assert OrderExecutor.resolve_time_in_force("market", %{}, "us_equity") == "day"
      assert OrderExecutor.resolve_time_in_force("market", %{}, "crypto") == "gtc"
    end

    test "params time_in_force overrides asset-class default in :market mode" do
      Application.put_env(:alpaca_trader, :order_type_mode, :market)

      params = %{"time_in_force" => "opg"}
      assert OrderExecutor.resolve_time_in_force("market", params, "us_equity") == "opg"
    end
  end
end
