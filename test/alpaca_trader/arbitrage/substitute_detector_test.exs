defmodule AlpacaTrader.Arbitrage.SubstituteDetectorTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.Arbitrage.SubstituteDetector
  alias AlpacaTrader.BarsStore

  setup do
    BarsStore.put_all_bars(%{})
    :ok
  end

  test "returns nil when no substitutes defined" do
    assert {:ok, nil} = SubstituteDetector.detect("UNKNOWN_SYMBOL")
  end

  test "returns nil when bars not available" do
    # AAPL has MSFT as substitute, but no bars loaded
    assert {:ok, nil} = SubstituteDetector.detect("AAPL")
  end

  test "returns nil when z-score below threshold" do
    # Correlated series with no divergence
    bars_a = Enum.map(1..60, fn i -> %{"t" => "2026-01-#{String.pad_leading("#{i}", 2, "0")}", "c" => 150.0 + i * 0.1} end)
    bars_b = Enum.map(1..60, fn i -> %{"t" => "2026-01-#{String.pad_leading("#{i}", 2, "0")}", "c" => 300.0 + i * 0.2} end)

    BarsStore.put_all_bars(%{"AAPL" => bars_a, "MSFT" => bars_b})

    {:ok, result} = SubstituteDetector.detect("AAPL")
    assert result == nil
  end

  test "detects opportunity when z-score exceeds threshold" do
    # Create a series where the last point diverges sharply
    bars_a = Enum.map(1..59, fn i -> %{"t" => "2026-01-#{String.pad_leading("#{i}", 2, "0")}", "c" => 150.0 + i * 0.1} end)
    bars_a = bars_a ++ [%{"t" => "2026-03-01", "c" => 200.0}]  # sharp spike

    bars_b = Enum.map(1..60, fn i -> %{"t" => "2026-01-#{String.pad_leading("#{i}", 2, "0")}", "c" => 300.0 + i * 0.2} end)

    BarsStore.put_all_bars(%{"AAPL" => bars_a, "MSFT" => bars_b})

    {:ok, result} = SubstituteDetector.detect("AAPL")
    assert result != nil
    assert result.asset_a == "AAPL"
    assert result.asset_b == "MSFT"
    assert abs(result.z_score) > 2.0
    assert result.direction in [:long_a_short_b, :long_b_short_a]
  end

  test "returns strongest signal when multiple substitutes exist" do
    # BTC/USD has both IBIT and COIN as substitutes
    bars_btc = Enum.map(1..59, fn i -> %{"t" => "2026-01-#{String.pad_leading("#{i}", 2, "0")}", "c" => 100.0} end)
              ++ [%{"t" => "2026-03-01", "c" => 500.0}]

    bars_ibit = Enum.map(1..60, fn i -> %{"t" => "2026-01-#{String.pad_leading("#{i}", 2, "0")}", "c" => 50.0} end)
    bars_coin = Enum.map(1..60, fn i -> %{"t" => "2026-01-#{String.pad_leading("#{i}", 2, "0")}", "c" => 200.0} end)

    BarsStore.put_all_bars(%{"BTC/USD" => bars_btc, "IBIT" => bars_ibit, "COIN" => bars_coin})

    {:ok, result} = SubstituteDetector.detect("BTC/USD")
    assert result != nil
    assert result.asset_a == "BTC/USD"
    assert result.asset_b in ["IBIT", "COIN"]
  end
end
