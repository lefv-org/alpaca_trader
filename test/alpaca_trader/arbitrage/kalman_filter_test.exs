defmodule AlpacaTrader.Arbitrage.KalmanFilterTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Arbitrage.KalmanFilter

  test "converges toward true beta on synthetic linear data" do
    :rand.seed(:exsplus, {1, 2, 3})

    true_beta = 1.5
    prices_b = Enum.map(1..500, fn i -> 100.0 + i * 0.1 + :rand.normal() end)
    prices_a = Enum.map(prices_b, fn b -> true_beta * b + :rand.normal() * 0.5 end)

    final = KalmanFilter.final_ratio(prices_a, prices_b, delta: 1.0e-4)

    assert is_number(final)
    assert abs(final - true_beta) < 0.2, "expected ~#{true_beta}, got #{final}"
  end

  test "tracks a changing beta over time" do
    :rand.seed(:exsplus, {10, 20, 30})
    prices_b = Enum.map(1..400, fn _ -> 100.0 + :rand.normal() * 2 end)

    # First half: beta = 1.0. Second half: beta = 2.0.
    prices_a =
      Enum.with_index(prices_b)
      |> Enum.map(fn {b, i} ->
        beta = if i < 200, do: 1.0, else: 2.0
        beta * b + :rand.normal() * 0.3
      end)

    # High delta → fast tracking of regime shifts
    {:ok, trace} = KalmanFilter.run(prices_a, prices_b, delta: 1.0e-2, r: 0.1)

    mid = elem(Enum.at(trace, 180), 0)
    final = elem(List.last(trace), 0)

    assert abs(mid - 1.0) < 0.25, "expected ~1.0 mid-series, got #{mid}"
    assert abs(final - 2.0) < 0.3, "expected ~2.0 at end, got #{final}"
  end

  test "returns error on mismatched lengths" do
    assert {:error, :length_mismatch} = KalmanFilter.run([1.0, 2.0], [1.0])
  end

  test "handles empty input" do
    assert {:ok, []} = KalmanFilter.run([], [])
    assert nil == KalmanFilter.final_ratio([], [])
  end
end
