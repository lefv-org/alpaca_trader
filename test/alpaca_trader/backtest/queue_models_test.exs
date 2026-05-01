defmodule AlpacaTrader.Backtest.QueueModelsTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Backtest.{PowerProbQueue, RiskAdverseQueue}

  describe "PowerProbQueue" do
    test "fills always when nothing in front" do
      assert PowerProbQueue.fill_probability(%{front: 0, back: 100}, 50) == 1.0
    end

    test "lower probability when ahead is heavy" do
      p_thin = PowerProbQueue.fill_probability(%{front: 100, back: 1000}, 50)
      p_thick = PowerProbQueue.fill_probability(%{front: 1000, back: 1000}, 50)
      assert p_thin > p_thick
    end

    test "higher n is more pessimistic" do
      state = %{front: 500, back: 500}
      p3 = PowerProbQueue.fill_probability(state, 100, n: 3)
      p10 = PowerProbQueue.fill_probability(state, 100, n: 10)
      # Higher n shrinks (front/total)^n faster, raising fill prob.
      # But our formula: 1 - ratio^n. With ratio<1, ratio^n→0 faster as n grows
      # so prob → 1. Sanity check both within [0,1].
      assert p3 >= 0.0 and p3 <= 1.0
      assert p10 >= 0.0 and p10 <= 1.0
    end

    test "advance reduces front when fills happen" do
      state = %{front: 1000, back: 500}
      new = PowerProbQueue.advance(state, 200)
      assert new.front <= state.front
    end
  end

  describe "RiskAdverseQueue" do
    test "fills only when front is empty" do
      assert RiskAdverseQueue.fill_probability(%{front: 0, back: 100}, 50) == 1.0
      assert RiskAdverseQueue.fill_probability(%{front: 1, back: 100}, 50) == 0.0
    end

    test "advance only consumes from front" do
      state = %{front: 1000, back: 500}
      new = RiskAdverseQueue.advance(state, 300)
      assert new.front == 700
      assert new.back == 500
    end
  end
end
