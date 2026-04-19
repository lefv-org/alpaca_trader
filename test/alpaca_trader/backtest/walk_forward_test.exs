defmodule AlpacaTrader.Backtest.WalkForwardTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Backtest.{Simulator, WalkForward}

  defp synthetic_cointegrated(n, rho, seed) do
    :rand.seed(:exsplus, {seed, seed + 1, seed + 2})

    closes_b =
      Enum.reduce(1..n, {[], 100.0}, fn _, {acc, prev} ->
        new = prev + :rand.normal() * 0.5
        {[new | acc], new}
      end)
      |> elem(0)
      |> Enum.reverse()

    {spreads, _} =
      Enum.reduce(1..n, {[], 0.0}, fn _, {acc, prev} ->
        new = rho * prev + :rand.normal() * 1.5
        {[new | acc], new}
      end)

    spreads = Enum.reverse(spreads)

    closes_a = Enum.zip(closes_b, spreads) |> Enum.map(fn {b, s} -> 1.2 * b + s end)

    {closes_a, closes_b}
  end

  test "produces N windows given sufficient data" do
    {ca, cb} = synthetic_cointegrated(2000, 0.5, 42)
    bars_map = %{"A" => ca, "B" => cb}
    pairs = [{"A", "B"}]

    result =
      WalkForward.run(pairs, bars_map,
        window_bars: 500,
        step_bars: 250,
        simulator_config: Map.put(Simulator.default_config(), :require_cointegration, false)
      )

    # (2000 - 500) / 250 + 1 = 7 windows
    assert length(result.windows) == 7
    assert result.summary.n_windows == 7
  end

  test "reports insufficient data when window too large" do
    {ca, cb} = synthetic_cointegrated(200, 0.5, 42)
    bars_map = %{"A" => ca, "B" => cb}

    result = WalkForward.run([{"A", "B"}], bars_map, window_bars: 500, step_bars: 250)

    assert result.summary.insufficient_data == true
    assert result.windows == []
  end

  test "computes per-pair robustness across windows" do
    {ca, cb} = synthetic_cointegrated(2000, 0.4, 42)
    {ca2, cb2} = synthetic_cointegrated(2000, 0.9, 99)
    bars_map = %{"A" => ca, "B" => cb, "C" => ca2, "D" => cb2}
    pairs = [{"A", "B"}, {"C", "D"}]

    result =
      WalkForward.run(pairs, bars_map,
        window_bars: 500,
        step_bars: 250,
        simulator_config: Map.put(Simulator.default_config(), :require_cointegration, false)
      )

    robustness = result.per_pair_robustness
    assert length(robustness) == 2

    Enum.each(robustness, fn r ->
      assert is_number(r.win_ratio)
      assert r.win_ratio >= 0.0 and r.win_ratio <= 1.0
      assert is_number(r.avg_window_return)
    end)
  end

  test "empty pairs list yields insufficient_data summary" do
    result = WalkForward.run([], %{}, window_bars: 500)
    assert result.summary.insufficient_data == true
  end

  test "per_pair_robustness includes sharpe and avg_window_return net of slippage config" do
    bars = %{
      "A" => Enum.map(1..800, fn i -> 100.0 + :math.sin(i / 10.0) end),
      "B" => Enum.map(1..800, fn i -> 100.0 + :math.cos(i / 10.0) end)
    }

    result =
      AlpacaTrader.Backtest.WalkForward.run([{"A", "B"}], bars,
        window_bars: 240,
        step_bars: 120,
        simulator_config: %{slippage_bps: 15.0}
      )

    assert [r | _] = result.per_pair_robustness
    assert Map.has_key?(r, :sharpe_window_annualized)
    assert is_number(r.sharpe_window_annualized)
  end
end
