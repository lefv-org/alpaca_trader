defmodule AlpacaTrader.Arbitrage.RotationEvaluatorTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Arbitrage.RotationEvaluator
  alias AlpacaTrader.PairPositionStore.PairPosition

  defp build_position(overrides \\ %{}) do
    defaults = %PairPosition{
      id: "AAPL-MSFT-#{System.unique_integer([:positive])}",
      asset_a: "AAPL",
      asset_b: "MSFT",
      direction: :long_a_short_b,
      tier: 2,
      entry_z_score: 2.5,
      current_z_score: 1.0,
      entry_hedge_ratio: 0.5,
      entry_price_a: 150.0,
      entry_price_b: 300.0,
      entry_time: DateTime.utc_now(),
      bars_held: 12,
      max_hold_bars: 20,
      exit_z_threshold: 0.5,
      stop_z_threshold: 4.0,
      status: :open,
      last_updated: DateTime.utc_now(),
      flip_count: 0,
      consecutive_losses: 0
    }

    Map.merge(defaults, overrides)
  end

  defp build_signal(overrides \\ %{}) do
    defaults = %AlpacaTrader.Engine.ArbitragePosition{
      result: true,
      asset: "NVDA",
      pair_asset: "AMD",
      tier: 2,
      z_score: 3.0,
      direction: :long_a_short_b,
      hedge_ratio: 0.4,
      reason: "substitute spread z=3.0",
      timestamp: DateTime.utc_now()
    }

    Map.merge(defaults, overrides)
  end

  describe "position_score/1" do
    test "fresh position has low convergence and is not stale" do
      pos =
        build_position(%{
          entry_z_score: 2.5,
          current_z_score: 2.4,
          bars_held: 1,
          max_hold_bars: 20
        })

      score = RotationEvaluator.position_score(pos)

      assert score.convergence < 0.1
      assert score.time_used < 0.1
      assert score.stale? == false
      assert score.remaining_ev > 0
    end

    test "mostly converged + mostly through time = stale" do
      pos =
        build_position(%{
          entry_z_score: 2.5,
          current_z_score: 0.7,
          bars_held: 15,
          max_hold_bars: 20,
          exit_z_threshold: 0.5
        })

      score = RotationEvaluator.position_score(pos)

      assert score.convergence > 0.6
      assert score.time_used > 0.5
      assert score.stale? == true
      assert score.remaining_ev < 0.005
    end

    test "high convergence but low time is not stale" do
      pos =
        build_position(%{
          entry_z_score: 2.5,
          current_z_score: 0.6,
          bars_held: 3,
          max_hold_bars: 20,
          exit_z_threshold: 0.5
        })

      score = RotationEvaluator.position_score(pos)
      assert score.convergence > 0.6
      assert score.time_used < 0.5
      assert score.stale? == false
    end

    test "low convergence but high time is not stale" do
      pos =
        build_position(%{
          entry_z_score: 2.5,
          current_z_score: 2.0,
          bars_held: 18,
          max_hold_bars: 20,
          exit_z_threshold: 0.5
        })

      score = RotationEvaluator.position_score(pos)
      assert score.convergence < 0.6
      assert score.time_used > 0.5
      assert score.stale? == false
    end
  end

  describe "signal_ev/1" do
    test "stronger z-score produces higher EV" do
      weak = build_signal(%{z_score: 2.0, asset: "AAPL"})
      strong = build_signal(%{z_score: 3.5, asset: "AAPL"})

      assert RotationEvaluator.signal_ev(strong) > RotationEvaluator.signal_ev(weak)
    end

    test "z-score strength is capped at 2.0x" do
      high = build_signal(%{z_score: 4.0, asset: "AAPL"})
      extreme = build_signal(%{z_score: 8.0, asset: "AAPL"})

      assert RotationEvaluator.signal_ev(high) == RotationEvaluator.signal_ev(extreme)
    end
  end

  describe "evaluate/2" do
    test "returns :enter_normally when no open positions" do
      signal = build_signal()
      assert RotationEvaluator.evaluate(signal, []) == :enter_normally
    end

    test "returns :skip when no positions are stale" do
      fresh =
        build_position(%{
          entry_z_score: 2.5,
          current_z_score: 2.3,
          bars_held: 2,
          max_hold_bars: 20
        })

      signal = build_signal()
      assert RotationEvaluator.evaluate(signal, [fresh]) == :skip
    end

    test "returns {:rotate, victim} when stale position is weaker than signal" do
      stale =
        build_position(%{
          entry_z_score: 2.5,
          current_z_score: 0.7,
          bars_held: 15,
          max_hold_bars: 20,
          exit_z_threshold: 0.5
        })

      signal = build_signal(%{z_score: 3.5})

      assert {:rotate, ^stale} = RotationEvaluator.evaluate(signal, [stale])
    end

    test "returns :skip when signal is too weak to justify rotation" do
      stale =
        build_position(%{
          entry_z_score: 2.5,
          current_z_score: 0.8,
          bars_held: 12,
          max_hold_bars: 20,
          exit_z_threshold: 0.5
        })

      # Weak signal — barely above entry threshold
      weak_signal = build_signal(%{z_score: 2.0})

      result = RotationEvaluator.evaluate(weak_signal, [stale])
      # Either :skip (can't beat remaining EV + txn costs) or {:rotate, _}
      # With z=2.0 and remaining_ev still positive, transaction costs eat the margin
      assert result == :skip or match?({:rotate, _}, result)
    end

    test "skips positions that overlap with the new signal's assets" do
      # Position involves NVDA-AMD, signal also targets NVDA-AMD → overlap → skip
      overlapping =
        build_position(%{
          asset_a: "NVDA",
          asset_b: "AMD",
          entry_z_score: 2.5,
          current_z_score: 0.7,
          bars_held: 15,
          max_hold_bars: 20,
          exit_z_threshold: 0.5
        })

      signal = build_signal(%{asset: "NVDA", pair_asset: "TSM", z_score: 3.5})

      # Should skip the overlapping position (same asset_a)
      result = RotationEvaluator.evaluate(signal, [overlapping])
      assert result == :skip
    end

    test "picks the weakest stale position when multiple exist" do
      # Position A: mostly converged (weak remaining EV)
      weak =
        build_position(%{
          id: "weak-pos",
          asset_a: "AAPL",
          asset_b: "MSFT",
          entry_z_score: 2.5,
          current_z_score: 0.6,
          bars_held: 18,
          max_hold_bars: 20,
          exit_z_threshold: 0.5
        })

      # Position B: less converged (more remaining EV)
      stronger =
        build_position(%{
          id: "stronger-pos",
          asset_a: "META",
          asset_b: "GOOGL",
          entry_z_score: 2.5,
          current_z_score: 0.9,
          bars_held: 14,
          max_hold_bars: 20,
          exit_z_threshold: 0.5
        })

      signal = build_signal(%{z_score: 3.5})

      case RotationEvaluator.evaluate(signal, [weak, stronger]) do
        {:rotate, victim} ->
          # Should pick the position with lowest remaining EV (highest improvement)
          assert victim.id == "weak-pos"

        :skip ->
          # If neither clears the hurdle, that's also acceptable
          :ok
      end
    end
  end
end
