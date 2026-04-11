defmodule AlpacaTrader.Arbitrage.BellmanFordTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Arbitrage.BellmanFord

  defp snapshot(bid, ask) do
    %{"latestQuote" => %{"bp" => bid, "ap" => ask}}
  end

  describe "detect_cycles/2" do
    test "returns empty list when no arbitrage exists" do
      # Prices are consistent — no cycle profit
      snapshots = %{
        "BTC/USD" => snapshot(60000.0, 60010.0),
        "ETH/USD" => snapshot(3000.0, 3001.0),
        "ETH/BTC" => snapshot(0.05, 0.05001)
      }

      cycles = BellmanFord.detect_cycles(snapshots)
      profitable = Enum.filter(cycles, fn c -> c.profit_pct > 0 end)
      assert profitable == []
    end

    test "detects a profitable triangular cycle" do
      # Artificially create a mispricing: ETH/BTC is too cheap
      # Fair: ETH/BTC ≈ 3000/60000 = 0.05
      # Set ETH/BTC ask to 0.04 (20% cheaper than fair)
      # Cycle: USD → BTC (buy) → ETH via ETH/BTC (buy cheap) → USD (sell ETH)
      snapshots = %{
        "BTC/USD" => snapshot(60000.0, 60000.0),
        "ETH/USD" => snapshot(3000.0, 3000.0),
        "ETH/BTC" => snapshot(0.04, 0.04)
      }

      cycles = BellmanFord.detect_cycles(snapshots, 0.0)
      profitable = Enum.filter(cycles, fn c -> c.profit_pct > 0 end)
      assert length(profitable) > 0

      cycle = hd(profitable)
      assert cycle.profit_pct > 0
      assert is_list(cycle.cycle)
      assert length(cycle.cycle) >= 3
    end

    test "handles missing or zero prices gracefully" do
      snapshots = %{
        "BTC/USD" => snapshot(0, 0),
        "ETH/USD" => snapshot(3000.0, 3001.0)
      }

      cycles = BellmanFord.detect_cycles(snapshots)
      assert is_list(cycles)
    end

    test "handles empty snapshots" do
      assert BellmanFord.detect_cycles(%{}) == []
    end
  end

  describe "currency_in_cycles?/2" do
    test "finds currency in a cycle" do
      cycles = [%{cycle: ["USD", "BTC", "ETH", "USD"], profit_pct: 0.5, edges: []}]
      assert BellmanFord.currency_in_cycles?("BTC", cycles)
      assert BellmanFord.currency_in_cycles?("ETH", cycles)
      assert BellmanFord.currency_in_cycles?("USD", cycles)
    end

    test "returns nil when currency not in any cycle" do
      cycles = [%{cycle: ["USD", "BTC", "ETH", "USD"], profit_pct: 0.5, edges: []}]
      refute BellmanFord.currency_in_cycles?("SOL", cycles)
    end

    test "returns nil for empty cycles" do
      refute BellmanFord.currency_in_cycles?("BTC", [])
    end
  end
end
