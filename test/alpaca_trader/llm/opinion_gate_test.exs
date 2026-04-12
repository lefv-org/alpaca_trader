defmodule AlpacaTrader.LLM.OpinionGateTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.LLM.OpinionGate
  alias AlpacaTrader.Engine.{ArbitragePosition, MarketContext}

  test "fallback returns confirm with 0.5 conviction" do
    f = OpinionGate.fallback()
    assert f.decision == "confirm"
    assert f.conviction == 0.5
  end

  test "evaluate returns fallback when no API key configured" do
    arb = %ArbitragePosition{
      asset: "AAPL", pair_asset: "MSFT", z_score: 2.5,
      direction: :long_a_short_b, tier: 2, action: :enter,
      reason: "test signal"
    }

    ctx = %MarketContext{
      clock: %{"is_open" => false},
      account: %{"equity" => "100000"},
      positions: [], orders: [], quotes: %{}
    }

    {:ok, opinion} = OpinionGate.evaluate(arb, ctx)
    # Without ANTHROPIC_API_KEY, should fall back
    assert opinion.conviction == 0.5
    assert opinion.decision == "confirm"
  end

  test "min_conviction is 0.3" do
    assert OpinionGate.min_conviction() == 0.3
  end
end
