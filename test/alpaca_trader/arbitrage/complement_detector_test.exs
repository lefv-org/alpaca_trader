defmodule AlpacaTrader.Arbitrage.ComplementDetectorTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.Arbitrage.ComplementDetector
  alias AlpacaTrader.BarsStore

  setup do
    BarsStore.put_all_bars(%{})
    :ok
  end

  test "returns nil when no complements defined" do
    assert {:ok, nil} = ComplementDetector.detect("UNKNOWN_SYMBOL")
  end

  test "returns nil when bars not available" do
    assert {:ok, nil} = ComplementDetector.detect("AAPL")
  end

  test "returns nil when z-score below threshold (2.5)" do
    bars_a = Enum.map(1..60, fn i -> %{"t" => "#{i}", "c" => 150.0 + i * 0.1} end)
    bars_b = Enum.map(1..60, fn i -> %{"t" => "#{i}", "c" => 100.0 + i * 0.07} end)

    BarsStore.put_all_bars(%{"AAPL" => bars_a, "TSM" => bars_b})

    {:ok, result} = ComplementDetector.detect("AAPL")
    assert result == nil
  end

  test "detects opportunity when z-score exceeds 2.5" do
    bars_a = Enum.map(1..59, fn i -> %{"t" => "2026-01-#{String.pad_leading("#{i}", 2, "0")}", "c" => 150.0} end)
              ++ [%{"t" => "2026-03-01", "c" => 500.0}]

    bars_b = Enum.map(1..60, fn i -> %{"t" => "2026-01-#{String.pad_leading("#{i}", 2, "0")}", "c" => 100.0} end)

    BarsStore.put_all_bars(%{"AAPL" => bars_a, "TSM" => bars_b})

    {:ok, result} = ComplementDetector.detect("AAPL")
    assert result != nil
    assert result.asset_a == "AAPL"
    assert result.asset_b == "TSM"
    assert abs(result.z_score) > 2.5
  end
end
