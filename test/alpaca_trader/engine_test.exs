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

  describe "execute_trade/2" do
    test "holds when market is closed for equities" do
      ctx = build_context(%{clock: %{"is_open" => false}})
      params = %{"side" => "buy", "qty" => "1"}

      {:ok, result} = Engine.execute_trade(ctx, params)
      assert result.action == :hold
      assert result.reason == "market is closed"
    end

    test "holds when asset is not tradable" do
      ctx = build_context(%{asset: %{"tradable" => false, "class" => "us_equity"}})
      params = %{"side" => "buy", "qty" => "1"}

      {:ok, result} = Engine.execute_trade(ctx, params)
      assert result.action == :hold
      assert result.reason == "asset is not tradable"
    end

    test "holds with invalid params" do
      ctx = build_context()
      {:ok, result} = Engine.execute_trade(ctx, %{"side" => "hold"})
      assert result.action == :hold
      assert result.reason =~ "invalid params"
    end

    test "executes buy when market is open" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2/orders"
        Req.Test.json(conn, %{"id" => "o1", "symbol" => "AAPL", "status" => "accepted", "side" => "buy", "qty" => "1"})
      end)

      ctx = build_context(%{
        clock: %{"is_open" => true},
        asset: %{"tradable" => true, "class" => "us_equity"}
      })

      {:ok, result} = Engine.execute_trade(ctx, %{"side" => "buy", "qty" => "1"})
      assert result.action == :bought
      assert result.symbol == "AAPL"
      assert result.qty == "1"
      assert result.side == "buy"
      assert result.order["id"] == "o1"
    end

    test "executes sell when market is open" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        Req.Test.json(conn, %{"id" => "o2", "symbol" => "AAPL", "status" => "accepted", "side" => "sell", "qty" => "5"})
      end)

      ctx = build_context(%{
        clock: %{"is_open" => true},
        asset: %{"tradable" => true, "class" => "us_equity"}
      })

      {:ok, result} = Engine.execute_trade(ctx, %{"side" => "sell", "qty" => "5"})
      assert result.action == :sold
      assert result.side == "sell"
    end

    test "allows crypto when market is closed" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        Req.Test.json(conn, %{"id" => "o3", "symbol" => "BTC/USD", "status" => "accepted"})
      end)

      ctx = build_context(%{
        symbol: "BTC/USD",
        clock: %{"is_open" => false},
        asset: %{"tradable" => true, "class" => "crypto"}
      })

      {:ok, result} = Engine.execute_trade(ctx, %{"side" => "buy", "qty" => "0.001"})
      assert result.action == :bought
    end

    test "holds when order is rejected by API" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        Plug.Conn.send_resp(conn, 422, Jason.encode!(%{"message" => "insufficient qty"}))
      end)

      ctx = build_context(%{
        clock: %{"is_open" => true},
        asset: %{"tradable" => true, "class" => "us_equity"}
      })

      {:ok, result} = Engine.execute_trade(ctx, %{"side" => "buy", "qty" => "1"})
      assert result.action == :hold
      assert result.reason =~ "order rejected"
    end

    test "includes timestamp" do
      ctx = build_context(%{clock: %{"is_open" => false}})
      {:ok, result} = Engine.execute_trade(ctx, %{"side" => "buy", "qty" => "1"})
      assert %DateTime{} = result.timestamp
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
    setup do
      AlpacaTrader.PairPositionStore.clear()
      :ok
    end

    test "returns false when no opportunities across all tiers" do
      ctx = build_context(%{quotes: nil})
      {:ok, result} = Engine.is_in_arbitrage_position(ctx, "UNKNOWN")
      assert result.result == false
      assert result.action == :hold
      assert result.reason =~ "no opportunity"
    end

    test "returns false when crypto prices are consistent (no cycle)" do
      quotes = %{
        "BTC/USD" => %{"latestQuote" => %{"bp" => 60000.0, "ap" => 60010.0}},
        "ETH/USD" => %{"latestQuote" => %{"bp" => 3000.0, "ap" => 3001.0}},
        "ETH/BTC" => %{"latestQuote" => %{"bp" => 0.05, "ap" => 0.05001}}
      }

      ctx = build_context(%{quotes: quotes})
      {:ok, result} = Engine.is_in_arbitrage_position(ctx, "BTC")
      assert result.result == false
    end

    test "Tier 1: detects Bellman-Ford cycle with action :enter" do
      quotes = %{
        "BTC/USD" => %{"latestQuote" => %{"bp" => 60000.0, "ap" => 60000.0}},
        "ETH/USD" => %{"latestQuote" => %{"bp" => 3000.0, "ap" => 3000.0}},
        "ETH/BTC" => %{"latestQuote" => %{"bp" => 0.04, "ap" => 0.04}}
      }

      ctx = build_context(%{quotes: quotes})
      {:ok, result} = Engine.is_in_arbitrage_position(ctx, "BTC")
      assert result.result == true
      assert result.tier == 1
      assert result.action == :enter
      assert result.spread > 0
    end

    test "carries asset name to result" do
      ctx = build_context(%{quotes: %{}})
      {:ok, result} = Engine.is_in_arbitrage_position(ctx, "ETH")
      assert result.asset == "ETH"
    end

    test "finds related positions by asset name" do
      ctx = build_context(%{
        quotes: %{},
        positions: [
          %{"symbol" => "BTC/USD", "qty" => "0.5"},
          %{"symbol" => "AAPL", "qty" => "10"},
          %{"symbol" => "BTC/USDT", "qty" => "0.3"}
        ]
      })

      {:ok, result} = Engine.is_in_arbitrage_position(ctx, "BTC")
      assert length(result.related_positions) == 2
    end

    test "TAKE PROFIT: exits when z-score reverts below threshold" do
      # Simulate an open position with z-score that has reverted
      AlpacaTrader.BarsStore.put_all_bars(%{
        "AAPL" => Enum.map(1..60, fn i -> %{"t" => "2026-01-#{String.pad_leading("#{i}", 2, "0")}", "c" => 150.0 + i * 0.1} end),
        "MSFT" => Enum.map(1..60, fn i -> %{"t" => "2026-01-#{String.pad_leading("#{i}", 2, "0")}", "c" => 300.0 + i * 0.2} end)
      })

      AlpacaTrader.PairPositionStore.open_position(%{
        asset_a: "AAPL", asset_b: "MSFT", direction: :long_a_short_b,
        tier: 2, z_score: 2.5, hedge_ratio: 0.5
      })

      ctx = build_context(%{quotes: %{}})
      {:ok, result} = Engine.is_in_arbitrage_position(ctx, "AAPL")
      # Z-score of correlated series with no divergence should be near 0 → TAKE PROFIT
      assert result.result == true
      assert result.action == :exit
      assert result.reason =~ "TAKE PROFIT"
    end

    test "TIME EXIT: exits after max bars held" do
      AlpacaTrader.BarsStore.put_all_bars(%{
        "NVDA" => Enum.map(1..60, fn i -> %{"t" => "2026-01-#{String.pad_leading("#{i}", 2, "0")}", "c" => 800.0 + i * 1.0} end),
        "AMD" => Enum.map(1..60, fn i -> %{"t" => "2026-01-#{String.pad_leading("#{i}", 2, "0")}", "c" => 150.0 + i * 0.2} end)
      })

      {:ok, pos} = AlpacaTrader.PairPositionStore.open_position(%{
        asset_a: "NVDA", asset_b: "AMD", direction: :long_a_short_b,
        tier: 2, z_score: 2.5, hedge_ratio: 0.3
      })

      # Simulate 20 ticks (max_hold_bars for tier 2)
      for _ <- 1..20, do: AlpacaTrader.PairPositionStore.tick(pos.id, 1.5)

      ctx = build_context(%{quotes: %{}})
      {:ok, result} = Engine.is_in_arbitrage_position(ctx, "NVDA")
      assert result.result == true
      assert result.action == :exit
      assert result.reason =~ "TIME EXIT"
    end

    test "HOLD: keeps position when z-score is between thresholds" do
      # Noisy correlated pair → z ≈ 1.12, between exit_z=0.5 and stop_z=4.0
      bars_a = Enum.map(1..60, fn i ->
        %{"t" => "2026-01-#{String.pad_leading("#{i}", 2, "0")}", "c" => 150.0 + i * 1.0 + :math.sin(i / 3.0) * 2.0}
      end)
      bars_b = Enum.map(1..60, fn i ->
        %{"t" => "2026-01-#{String.pad_leading("#{i}", 2, "0")}", "c" => 300.0 + i * 2.0 + :math.cos(i / 3.0) * 3.0}
      end)

      AlpacaTrader.BarsStore.put_all_bars(%{"AAPL" => bars_a, "MSFT" => bars_b})

      AlpacaTrader.PairPositionStore.open_position(%{
        asset_a: "AAPL", asset_b: "MSFT", direction: :long_a_short_b,
        tier: 2, z_score: 2.5, hedge_ratio: 0.5
      })

      ctx = build_context(%{quotes: %{}})
      {:ok, result} = Engine.is_in_arbitrage_position(ctx, "AAPL")
      assert result.action == :hold
      assert result.reason =~ "HOLD"
    end
  end

  describe "scan_arbitrage/1" do
    setup do
      AlpacaTrader.PairPositionStore.clear()

      AlpacaTrader.AssetStore.put_assets([
        %{"symbol" => "AAPL", "class" => "us_equity", "tradable" => true},
        %{"symbol" => "BTC/USD", "class" => "crypto", "tradable" => true},
        %{"symbol" => "ETH/USD", "class" => "crypto", "tradable" => true}
      ])

      :ok
    end

    test "scans all assets from the store" do
      ctx = build_context()
      {:ok, result} = Engine.scan_arbitrage(ctx)

      assert result.scanned == 3
      assert result.hits == 0
      assert result.opportunities == []
      assert %DateTime{} = result.timestamp
    end

    test "returns ArbitrageScanResult struct with executed: 0 for dry run" do
      ctx = build_context()
      {:ok, result} = Engine.scan_arbitrage(ctx)
      assert %Engine.ArbitrageScanResult{} = result
      assert result.executed == 0
      assert result.trades == []
    end
  end

  describe "scan_and_execute/1" do
    setup do
      AlpacaTrader.PairPositionStore.clear()

      AlpacaTrader.AssetStore.put_assets([
        %{"symbol" => "AAPL", "class" => "us_equity", "tradable" => true},
        %{"symbol" => "BTC/USD", "class" => "crypto", "tradable" => true}
      ])

      :ok
    end

    test "scans and returns result with trade fields" do
      ctx = build_context()
      {:ok, result} = Engine.scan_and_execute(ctx)

      assert result.scanned == 2
      assert result.hits == 0
      assert result.executed == 0
      assert result.trades == []
    end

    test "returns ArbitrageScanResult struct" do
      ctx = build_context()
      {:ok, result} = Engine.scan_and_execute(ctx)
      assert %Engine.ArbitrageScanResult{} = result
    end
  end
end
