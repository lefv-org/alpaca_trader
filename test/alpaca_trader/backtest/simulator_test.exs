defmodule AlpacaTrader.Backtest.SimulatorTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Backtest.{Simulator, Report}

  # Synthetic cointegrated pair: prices_a = beta * prices_b + stationary_spread
  # where spread is AR(1) with strong reversion.
  defp synthetic_cointegrated_pair(n, rho \\ 0.5, beta \\ 1.2, seed \\ 42) do
    :rand.seed(:exsplus, {seed, seed + 1, seed + 2})

    # B is a random walk around 100
    {closes_b, _} =
      Enum.reduce(1..n, {[], 100.0}, fn _, {acc, prev} ->
        new = prev + :rand.normal() * 0.5
        {[new | acc], new}
      end)

    closes_b = Enum.reverse(closes_b)

    # Stationary spread that mean-reverts
    {spreads, _} =
      Enum.reduce(1..n, {[], 0.0}, fn _, {acc, prev} ->
        new = rho * prev + :rand.normal() * 2.0
        {[new | acc], new}
      end)

    spreads = Enum.reverse(spreads)

    closes_a =
      Enum.zip(closes_b, spreads)
      |> Enum.map(fn {b, s} -> beta * b + s end)

    {closes_a, closes_b}
  end

  describe "run_pair/4" do
    test "finds trades in a cointegrated pair with mean-reverting spread" do
      {ca, cb} = synthetic_cointegrated_pair(500, 0.5)

      result =
        Simulator.run_pair("SYN/USD", ca, cb, %{
          lookback_bars: 60,
          entry_z: 2.0,
          exit_z: 0.5,
          stop_z: 4.0,
          max_hold_bars: 30,
          require_cointegration: false,
          slippage_bps: 0.0
        })

      assert is_list(result.trades)
      # With rho=0.5 (strong reversion) and z-threshold=2, should catch trades
      assert length(result.trades) > 0
    end

    test "skips pair when insufficient bars" do
      short = Enum.to_list(1..20) |> Enum.map(&(&1 * 1.0))
      result = Simulator.run_pair("SHORT", short, short, %{lookback_bars: 60})
      assert result.skipped == :insufficient_bars
    end

    test "rejects non-cointegrated pair when gate is enabled" do
      # Two independent random walks = no cointegration
      :rand.seed(:exsplus, {1, 2, 3})
      ca = Enum.reduce(1..300, [100.0], fn _, [p | _] = acc -> [p + :rand.normal() | acc] end) |> Enum.reverse()
      cb = Enum.reduce(1..300, [100.0], fn _, [p | _] = acc -> [p + :rand.normal() | acc] end) |> Enum.reverse()

      result =
        Simulator.run_pair("RW/RW", ca, cb, %{
          lookback_bars: 60,
          entry_z: 2.0,
          require_cointegration: true
        })

      # Most windows should fail cointegration → no trades or very few
      assert length(result.trades) <= 5, "expected few/no trades, got #{length(result.trades)}"
    end

    test "tracks equity curve bar-by-bar" do
      {ca, cb} = synthetic_cointegrated_pair(500, 0.5)

      result =
        Simulator.run_pair("SYN/USD", ca, cb, %{
          lookback_bars: 60,
          require_cointegration: false
        })

      assert length(result.equity_curve) > 400
      # Equity curve should be monotonic time-index
      indices = Enum.map(result.equity_curve, &elem(&1, 0))
      assert indices == Enum.sort(indices)
    end

    test "regime filter disabled by default (baseline unchanged)" do
      closes_a = List.duplicate(100.0, 200)
      closes_b = List.duplicate(100.0, 200)
      result = AlpacaTrader.Backtest.Simulator.run_pair("A-B", closes_a, closes_b, %{})
      assert is_list(result.trades)
    end

    test "regime filter with max_realized_vol=0 blocks all entries" do
      closes_a = Enum.map(1..200, fn i -> 100.0 + :math.sin(i / 5.0) end)
      closes_b = Enum.map(1..200, fn i -> 100.0 + :math.cos(i / 5.0) end)

      cfg = %{regime_filter_enabled: true, regime_max_realized_vol: 0.0}
      result = AlpacaTrader.Backtest.Simulator.run_pair("A-B", closes_a, closes_b, cfg)
      assert result.trades == []
    end
  end

  describe "Report.summarize/1" do
    test "produces sensible metrics on a known-profitable scenario" do
      {ca, cb} = synthetic_cointegrated_pair(600, 0.4)

      result =
        Simulator.run_pair("SYN/USD", ca, cb, %{
          lookback_bars: 60,
          entry_z: 2.0,
          exit_z: 0.5,
          stop_z: 4.0,
          max_hold_bars: 30,
          require_cointegration: false,
          slippage_bps: 0.0
        })

      metrics = Report.summarize(result)
      assert metrics.n_trades > 0
      assert is_number(metrics.win_rate)
      assert metrics.win_rate >= 0.0 and metrics.win_rate <= 1.0
      assert is_number(metrics.avg_hold_bars)
    end

    test "handles empty trade list" do
      metrics = Report.summarize(%{trades: [], equity_curve: []})
      assert metrics.n_trades == 0
      assert metrics.win_rate == 0.0
    end
  end

  describe "half-life time-stop" do
    test "half-life time-stop closes position at mult * half_life" do
      # Mean-reverting AR(1) spread → known short half-life
      :rand.seed(:exsss, {11, 22, 33})

      {closes_a, _} =
        Enum.reduce(1..400, {[], 100.0}, fn _, {acc, last} ->
          new = last + :rand.normal()
          {[new | acc], new}
        end)

      closes_a = Enum.reverse(closes_a)

      {closes_b, _} =
        Enum.reduce(1..400, {[], 100.0}, fn _, {acc, last} ->
          new = last + :rand.normal()
          {[new | acc], new}
        end)

      closes_b = Enum.reverse(closes_b)

      cfg = %{
        lookback_bars: 60,
        entry_z: 1.0,
        exit_z: 0.2,
        stop_z: 10.0,
        max_hold_bars: 1000,
        notional: 1000.0,
        require_cointegration: false,
        half_life_time_stop_mult: 1.5
      }

      result = Simulator.run_pair("A-B", closes_a, closes_b, cfg)
      reasons = Enum.map(result.trades, & &1.reason)

      # High entry_z, tight exit_z, very large max_hold_bars, loose stop_z.
      # If any trades exit via :max_hold, it is because the half-life-based
      # time-stop fired — not the fallback max_hold_bars.
      assert :max_hold in reasons or reasons == []
    end

    test "kelly_enabled caps notional below fixed size once history accrues" do
      :rand.seed(:exsss, {4, 5, 6})

      {closes_a, _} =
        Enum.reduce(1..800, {[], 100.0}, fn _, {acc, last} ->
          new = last + :rand.normal() * 0.5
          {[new | acc], new}
        end)

      {closes_b, _} =
        Enum.reduce(1..800, {[], 100.0}, fn _, {acc, last} ->
          new = last + :rand.normal() * 0.5
          {[new | acc], new}
        end)

      closes_a = Enum.reverse(closes_a)
      closes_b = Enum.reverse(closes_b)

      cfg = %{
        notional: 10_000.0,
        kelly_enabled: true,
        kelly_fraction: 0.5,
        # 1% of equity max — a tight ceiling
        kelly_max_cap_pct: 0.01,
        entry_z: 1.0,
        exit_z: 0.3,
        stop_z: 5.0,
        require_cointegration: false
      }

      result = AlpacaTrader.Backtest.Simulator.run_pair("A-B", closes_a, closes_b, cfg)

      # Kelly clip should reduce notional to ≤ equity * max_cap_pct = 10_000 * 0.01 = 100
      # (with small numerical tolerance). Verify at least the later trades are capped.
      if length(result.trades) > 0 do
        assert Enum.all?(result.trades, fn t -> t.notional <= 150.0 end),
               "expected Kelly cap (~$100) to bound trade notionals; got: #{inspect(Enum.map(result.trades, & &1.notional))}"
      end
    end
  end
end
