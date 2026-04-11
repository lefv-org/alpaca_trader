defmodule AlpacaTrader.EngineTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Engine
  alias AlpacaTrader.Engine.MarketContext
  alias AlpacaTrader.Engine.PurchaseContext

  defp build_context(overrides \\ %{}) do
    defaults = %MarketContext{
      symbol: "AAPL",
      account: %{"equity" => "100000", "buying_power" => "200000", "cash" => "50000"},
      position: nil,
      clock: %{"is_open" => true, "next_close" => "2026-04-11T16:00:00-04:00"},
      asset: %{"symbol" => "AAPL", "tradable" => true, "name" => "Apple Inc."},
      bars: nil,
      positions: [],
      orders: []
    }

    Map.merge(defaults, overrides)
  end

  describe "execute_trade/1" do
    test "returns {:ok, %PurchaseContext{}} with :hold action" do
      ctx = build_context()
      assert {:ok, %PurchaseContext{action: :hold}} = Engine.execute_trade(ctx)
    end

    test "carries symbol from context to result" do
      ctx = build_context(%{symbol: "MSFT"})
      {:ok, result} = Engine.execute_trade(ctx)
      assert result.symbol == "MSFT"
    end

    test "includes a reason" do
      ctx = build_context()
      {:ok, result} = Engine.execute_trade(ctx)
      assert is_binary(result.reason)
    end

    test "includes a timestamp" do
      ctx = build_context()
      {:ok, result} = Engine.execute_trade(ctx)
      assert %DateTime{} = result.timestamp
    end

    test "returns nil qty and side for hold" do
      ctx = build_context()
      {:ok, result} = Engine.execute_trade(ctx)
      assert result.qty == nil
      assert result.side == nil
    end

    test "returns nil order for hold" do
      ctx = build_context()
      {:ok, result} = Engine.execute_trade(ctx)
      assert result.order == nil
    end
  end

  describe "MarketContext struct" do
    test "can be constructed with all fields" do
      ctx = build_context(%{
        position: %{"symbol" => "AAPL", "qty" => "10"},
        bars: [%{"o" => 150, "h" => 155, "l" => 149, "c" => 153, "v" => 1000}],
        positions: [%{"symbol" => "AAPL", "qty" => "10"}],
        orders: [%{"id" => "o1", "symbol" => "AAPL", "status" => "filled"}]
      })

      assert ctx.symbol == "AAPL"
      assert ctx.position["qty"] == "10"
      assert length(ctx.bars) == 1
      assert length(ctx.positions) == 1
      assert length(ctx.orders) == 1
    end
  end

  describe "is_in_arbitrage_position/2" do
    test "returns {:ok, %ArbitragePosition{}} with result: false" do
      ctx = build_context()
      assert {:ok, %Engine.ArbitragePosition{result: false}} = Engine.is_in_arbitrage_position(ctx, "BTC")
    end

    test "carries asset name to result" do
      ctx = build_context()
      {:ok, result} = Engine.is_in_arbitrage_position(ctx, "ETH")
      assert result.asset == "ETH"
    end

    test "includes a reason and timestamp" do
      ctx = build_context()
      {:ok, result} = Engine.is_in_arbitrage_position(ctx, "BTC")
      assert is_binary(result.reason)
      assert %DateTime{} = result.timestamp
    end

    test "finds related positions by asset name" do
      ctx = build_context(%{
        positions: [
          %{"symbol" => "BTC/USD", "qty" => "0.5", "side" => "long"},
          %{"symbol" => "AAPL", "qty" => "10", "side" => "long"},
          %{"symbol" => "BTC/USDT", "qty" => "0.3", "side" => "short"}
        ]
      })

      {:ok, result} = Engine.is_in_arbitrage_position(ctx, "BTC")
      assert length(result.related_positions) == 2
    end

    test "returns empty related_positions when no match" do
      ctx = build_context(%{positions: [%{"symbol" => "AAPL", "qty" => "10"}]})
      {:ok, result} = Engine.is_in_arbitrage_position(ctx, "BTC")
      assert result.related_positions == []
    end
  end
end
