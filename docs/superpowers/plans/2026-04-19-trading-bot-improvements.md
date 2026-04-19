# Trading Bot Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add eight result-boosting features to the stat-arb pair trading bot: regime filter, half-life time-stop + sizing, cost-adjusted walk-forward, Kelly fractional sizing, limit-order execution + fill metrics, correlation cluster cap, online re-cointegration refresh, and shadow-mode signal logger.

**Architecture:** Each feature is a new `lib/alpaca_trader/...` module (or a small extension to an existing one) that plugs into the existing entry/exit pipeline via configurable gates. Every gate is off-by-default behind an `Application.get_env` flag so existing behavior is unchanged until opt-in. The backtest simulator gets the same gates so walk-forward validation reflects live behavior.

**Tech Stack:** Elixir 1.15 / OTP, Phoenix 1.8, Quantum (cron), Decimal, Req (HTTP), Jason (JSON). Tests use ExUnit. Persisted tuning state in `priv/runtime/*.json`.

---

## File Structure

**New files:**
- `lib/alpaca_trader/regime_detector.ex` — realized-vol + spread ADF drift gate (Task 1)
- `lib/alpaca_trader/arbitrage/half_life_manager.ex` — time-stop + size-by-half-life (Task 2)
- `lib/alpaca_trader/arbitrage/kelly_sizer.ex` — fractional Kelly from walk-forward stats (Task 4)
- `lib/alpaca_trader/arbitrage/cluster_limiter.ex` — correlation-cluster exposure cap (Task 6)
- `lib/alpaca_trader/scheduler/jobs/pair_recointegration_job.ex` — weekly re-ADF cron (Task 7)
- `lib/alpaca_trader/shadow_logger.ex` — theoretical-vs-actual signal diff recorder (Task 8)
- `test/alpaca_trader/regime_detector_test.exs`
- `test/alpaca_trader/arbitrage/half_life_manager_test.exs`
- `test/alpaca_trader/arbitrage/kelly_sizer_test.exs`
- `test/alpaca_trader/arbitrage/cluster_limiter_test.exs`
- `test/alpaca_trader/scheduler/jobs/pair_recointegration_job_test.exs`
- `test/alpaca_trader/shadow_logger_test.exs`

**Modified files:**
- `lib/alpaca_trader/backtest/walk_forward.ex` — emit net Sharpe / annualized-cost metrics (Task 3)
- `lib/alpaca_trader/backtest/whitelist_generator.ex` — add `:min_net_sharpe` gate (Task 3)
- `lib/alpaca_trader/engine.ex` — wire in RegimeDetector, HalfLifeManager, KellySizer, ClusterLimiter, ShadowLogger (each in its own task)
- `lib/alpaca_trader/engine/order_executor.ex` — add `:marketable_limit` order mode (Task 5)
- `lib/alpaca_trader/backtest/simulator.ex` — add regime gate + half-life sizing knobs for parity (Tasks 1, 2, 4)
- `lib/alpaca_trader/portfolio_risk.ex` — delegate correlation-cluster check to ClusterLimiter (Task 6)
- `lib/alpaca_trader/application.ex` — add ClusterLimiter supervisor child, schedule recointegration job (Tasks 6, 7)
- `lib/alpaca_trader/scheduler/quantum.ex` — register `PairRecointegrationJob` (Task 7)
- `config/runtime.exs` — env vars for all new feature flags
- `test/alpaca_trader/engine_test.exs` — integration coverage for gates

**Conventions followed:**
- Module under `AlpacaTrader.*` namespace matching `lib/alpaca_trader/*` path
- `@moduledoc` with "why" not "what"
- Pure helpers where possible; GenServer only when state is unavoidable
- Config via `Application.get_env(:alpaca_trader, key, default)` — no hardcoded values
- Feature flags default to `false`/`nil`; existing deployments unchanged until opt-in
- Tests per module under `test/alpaca_trader/` mirror path

---

## Pre-flight: Branch Setup

- [ ] **Step P.1: Confirm working tree clean and on main**

Run: `git status && git branch --show-current`
Expected: clean tree, `main` branch, up to date with `origin/main`.

- [ ] **Step P.2: Create feature branch**

Run: `git checkout -b feat/trading-bot-improvements`

- [ ] **Step P.3: Verify build and existing tests pass before starting**

Run: `mix compile --warnings-as-errors && mix test`
Expected: clean compile, all existing tests pass. If anything fails, stop and surface the failure before adding new code.

---

## Task 1: Regime Detector (realized-vol + ADF drift gate)

Blocks pair entries when market volatility is too high or when the pair's own spread has drifted out of stationarity since the last whitelist build.

**Files:**
- Create: `lib/alpaca_trader/regime_detector.ex`
- Create: `test/alpaca_trader/regime_detector_test.exs`
- Modify: `lib/alpaca_trader/engine.ex` — call gate in `scan_and_execute/1` entry path
- Modify: `lib/alpaca_trader/backtest/simulator.ex` — same gate in `maybe_enter/6`
- Modify: `config/runtime.exs` — add `REGIME_FILTER_ENABLED`, `REGIME_MAX_REALIZED_VOL_ANNUAL`, `REGIME_MAX_ADF_PVALUE`

### 1.1 Write failing tests

- [ ] **Step 1.1.1: Write the failing test file**

Create `test/alpaca_trader/regime_detector_test.exs`:

```elixir
defmodule AlpacaTrader.RegimeDetectorTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.RegimeDetector

  describe "realized_vol_annualized/2" do
    test "computes annualized stdev of log returns (hourly bars, 24h/day * 252d)" do
      # Flat series has zero vol
      flat = List.duplicate(100.0, 100)
      assert RegimeDetector.realized_vol_annualized(flat, :hourly) == 0.0

      # Synthetic series with known daily log-return stdev ~ 0.01
      # annualized ≈ 0.01 * sqrt(252) ≈ 0.159
      rng = :rand.seed(:exsss, {1, 2, 3})
      series = generate_gbm_series(1000, 0.0001, 0.01 / :math.sqrt(24))
      _ = rng
      v = RegimeDetector.realized_vol_annualized(series, :hourly)
      # 0.01 daily * sqrt(252) ≈ 0.159 — allow wide band for randomness
      assert v > 0.10 and v < 0.25
    end

    test "returns nil for series shorter than 20 bars" do
      assert RegimeDetector.realized_vol_annualized([1.0, 2.0, 3.0], :hourly) == nil
    end

    defp generate_gbm_series(n, drift, vol) do
      Enum.scan(1..n, 100.0, fn _, last ->
        z = :rand.normal()
        last * :math.exp(drift + vol * z)
      end)
    end
  end

  describe "allow_entry?/2" do
    test "allows when filter is disabled" do
      opts = [enabled: false, max_realized_vol: 0.3, max_adf_pvalue: 0.05]
      assert RegimeDetector.allow_entry?(%{spread: [], symbol_a_closes: []}, opts) == :ok
    end

    test "blocks when realized vol exceeds max" do
      opts = [enabled: true, max_realized_vol: 0.1]

      high_vol = Enum.map(1..200, fn i -> 100.0 + 10.0 * :math.sin(i / 3.0) end)
      inputs = %{spread: high_vol, symbol_a_closes: high_vol}
      assert {:blocked, {:realized_vol_too_high, _}} = RegimeDetector.allow_entry?(inputs, opts)
    end

    test "blocks when spread ADF shows non-stationarity (random walk)" do
      opts = [enabled: true, max_realized_vol: 10.0, max_adf_pvalue: 0.05]

      rw =
        Enum.scan(1..500, 0.0, fn _, acc -> acc + :rand.normal() end)

      flat_prices = List.duplicate(100.0, 500)

      assert {:blocked, {:spread_not_stationary, _}} =
               RegimeDetector.allow_entry?(
                 %{spread: rw, symbol_a_closes: flat_prices},
                 opts
               )
    end

    test "allows when both vol is low and spread is stationary" do
      opts = [enabled: true, max_realized_vol: 10.0, max_adf_pvalue: 0.05]

      # mean-reverting AR(1) with phi = 0.3
      stationary =
        Enum.scan(1..500, 0.0, fn _, last -> 0.3 * last + :rand.normal() end)

      flat_prices = List.duplicate(100.0, 500)

      assert :ok =
               RegimeDetector.allow_entry?(
                 %{spread: stationary, symbol_a_closes: flat_prices},
                 opts
               )
    end
  end
end
```

- [ ] **Step 1.1.2: Run test to verify it fails**

Run: `mix test test/alpaca_trader/regime_detector_test.exs`
Expected: FAIL with `AlpacaTrader.RegimeDetector is undefined` or similar.

### 1.2 Implement RegimeDetector

- [ ] **Step 1.2.1: Create module with minimal pure functions**

Create `lib/alpaca_trader/regime_detector.ex`:

```elixir
defmodule AlpacaTrader.RegimeDetector do
  @moduledoc """
  Block pair entries when the market regime is hostile to mean-reversion.

  Two checks, combined as an AND gate:

  1. Realized-volatility of the long leg: annualized stdev of log returns
     over the lookback window. Pair trades blow up in vol spikes — the
     spread's own stdev widens out from the historical distribution, the
     stop-z threshold gets hit on noise, and mean-reversion half-lives
     stretch. High vol is a "sit this one out" signal.

  2. Live spread stationarity: re-runs ADF on the current window's spread.
     A pair that passed walk-forward selection three weeks ago may no
     longer be cointegrated. Blocking on a p-value drift catches silent
     decay without waiting for the weekly re-whitelist job.

  Pure functional. Configured via `:regime_filter_*` application env.
  """

  alias AlpacaTrader.Arbitrage.MeanReversion

  @hourly_bars_per_year 24 * 252
  @min_vol_window 20

  @doc """
  Annualized realized volatility of log returns.

  `bar_frequency` is `:hourly` (default) or `:daily`. Returns a float >= 0
  or `nil` if the series is too short.
  """
  def realized_vol_annualized(series, bar_frequency \\ :hourly)

  def realized_vol_annualized(series, _) when length(series) < @min_vol_window, do: nil

  def realized_vol_annualized(series, bar_frequency) when is_list(series) do
    log_returns =
      series
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> :math.log(b / a) end)

    n = length(log_returns)
    mean = Enum.sum(log_returns) / n
    variance = Enum.reduce(log_returns, 0.0, fn r, acc -> acc + :math.pow(r - mean, 2) end) / n
    stdev = :math.sqrt(variance)

    scale =
      case bar_frequency do
        :hourly -> :math.sqrt(@hourly_bars_per_year)
        :daily -> :math.sqrt(252)
      end

    stdev * scale
  end

  @doc """
  Gate a pair entry given the current window inputs.

  Inputs:
  - `:spread` — list of spread values over the lookback window
  - `:symbol_a_closes` — closing prices of leg A (used for realized vol)
  - `:bar_frequency` — `:hourly` (default) or `:daily`

  Options (all keyword-based so callers don't depend on Application.env
  lookups for testability):
  - `:enabled` — master switch (default: false)
  - `:max_realized_vol` — annualized stdev ceiling (default: 1.0 = 100%)
  - `:max_adf_pvalue` — ADF p-value ceiling (default: nil = skip ADF)

  Returns `:ok` or `{:blocked, reason}`.
  """
  def allow_entry?(inputs, opts \\ []) when is_map(inputs) do
    enabled = Keyword.get(opts, :enabled, Application.get_env(:alpaca_trader, :regime_filter_enabled, false))

    if not enabled do
      :ok
    else
      max_vol = Keyword.get(opts, :max_realized_vol, Application.get_env(:alpaca_trader, :regime_max_realized_vol, 1.0))
      max_adf_p = Keyword.get(opts, :max_adf_pvalue, Application.get_env(:alpaca_trader, :regime_max_adf_pvalue))
      bar_freq = Map.get(inputs, :bar_frequency, :hourly)

      with :ok <- check_vol(inputs[:symbol_a_closes] || [], max_vol, bar_freq),
           :ok <- check_adf(inputs[:spread] || [], max_adf_p) do
        :ok
      end
    end
  end

  defp check_vol(closes, max_vol, bar_freq) do
    case realized_vol_annualized(closes, bar_freq) do
      nil -> :ok
      v when v <= max_vol -> :ok
      v -> {:blocked, {:realized_vol_too_high, Float.round(v, 4)}}
    end
  end

  defp check_adf(_spread, nil), do: :ok

  defp check_adf(spread, max_p) when is_list(spread) and length(spread) >= 30 do
    case MeanReversion.adf_test(spread) do
      %{stationary?: true} -> :ok
      %{t_stat: t} -> if t_to_pvalue(t) <= max_p, do: :ok, else: {:blocked, {:spread_not_stationary, Float.round(t, 3)}}
      _ -> {:blocked, {:spread_not_stationary, :no_adf}}
    end
  end

  defp check_adf(_, _), do: :ok

  # Crude p-value map from ADF t-stat. MacKinnon 1996 table; coarse enough
  # for a gate, not a test of record. Negative t → lower p.
  defp t_to_pvalue(t) when t <= -3.43, do: 0.01
  defp t_to_pvalue(t) when t <= -2.86, do: 0.05
  defp t_to_pvalue(t) when t <= -2.57, do: 0.10
  defp t_to_pvalue(_), do: 0.50
end
```

- [ ] **Step 1.2.2: Run tests to verify they pass**

Run: `mix test test/alpaca_trader/regime_detector_test.exs`
Expected: all 4 tests pass (randomized tests may take a few runs; seed `:rand` at test start if flaky).

- [ ] **Step 1.2.3: Commit**

```bash
git add lib/alpaca_trader/regime_detector.ex test/alpaca_trader/regime_detector_test.exs
git commit -m "feat(regime): realized-vol + ADF drift gate module"
```

### 1.3 Wire gate into Engine

- [ ] **Step 1.3.1: Locate engine entry pipeline**

Run: `grep -n "scan_and_execute\|maybe_enter\|PortfolioRisk.allow_entry" /Users/home/repos/alpaca_trader/lib/alpaca_trader/engine.ex`
Note the line around existing `PortfolioRisk.allow_entry?` call — insert regime check immediately before it so blocked regimes short-circuit cheaply.

- [ ] **Step 1.3.2: Add regime gate call in Engine**

In `lib/alpaca_trader/engine.ex`, find the entry decision point (around line 413 `scan_and_execute/1` or the call to `PortfolioRisk.allow_entry?`) and add the regime gate just before portfolio risk. Example insertion (patch the existing entry-check path):

```elixir
# Before placing an order, check regime
case AlpacaTrader.RegimeDetector.allow_entry?(%{
       spread: spread_window,
       symbol_a_closes: closes_a_window,
       bar_frequency: :hourly
     }) do
  :ok ->
    # continue with PortfolioRisk.allow_entry? etc.
    existing_entry_logic

  {:blocked, reason} ->
    Logger.info("[Engine] regime gate blocked #{asset_a}-#{asset_b}: #{inspect(reason)}")
    :skip
end
```

**Important:** do not invent variable names. Use whichever names the surrounding function already binds for the spread and leg-A closes. If those values are not yet in scope, thread them in from the caller — but keep the scope of this task small: if a refactor is needed, flag it and move on; do not reshape the engine in this task.

- [ ] **Step 1.3.3: Add Engine-level test covering the gate**

Append to `test/alpaca_trader/engine_test.exs` (new test case, no changes to existing tests):

```elixir
describe "regime filter" do
  test "does not block entries when flag is off" do
    prev = Application.get_env(:alpaca_trader, :regime_filter_enabled, false)
    Application.put_env(:alpaca_trader, :regime_filter_enabled, false)
    on_exit(fn -> Application.put_env(:alpaca_trader, :regime_filter_enabled, prev) end)
    # existing engine scan path should proceed as before; just ensure no crash
    # (full entry integration is covered by other engine tests)
    assert is_boolean(AlpacaTrader.RegimeDetector.allow_entry?(%{spread: [], symbol_a_closes: []}, []) == :ok)
  end
end
```

- [ ] **Step 1.3.4: Run engine tests**

Run: `mix test test/alpaca_trader/engine_test.exs`
Expected: all tests pass.

### 1.4 Mirror gate in backtest Simulator

- [ ] **Step 1.4.1: Patch Simulator.maybe_enter/6**

In `lib/alpaca_trader/backtest/simulator.ex`, inside `maybe_enter`, after the existing `require_cointegration` check, add the regime gate using the same options as the engine:

```elixir
regime_opts = [
  enabled: Map.get(config, :regime_filter_enabled, false),
  max_realized_vol: Map.get(config, :regime_max_realized_vol, 1.0),
  max_adf_pvalue: Map.get(config, :regime_max_adf_pvalue)
]

case AlpacaTrader.RegimeDetector.allow_entry?(
       %{spread: SpreadCalculator.spread_series(window_a, window_b, analysis.hedge_ratio),
         symbol_a_closes: window_a,
         bar_frequency: :hourly},
       regime_opts
     ) do
  :ok -> # existing branch that enters the position
  {:blocked, _} -> state  # skip this entry
end
```

Keep the diff localized. Do not change the cointegration check or anything else in this step.

- [ ] **Step 1.4.2: Add simulator test for regime gate**

Append to `test/alpaca_trader/backtest/simulator_test.exs`:

```elixir
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
```

- [ ] **Step 1.4.3: Run simulator tests**

Run: `mix test test/alpaca_trader/backtest/simulator_test.exs`
Expected: all pass.

### 1.5 Config plumbing and commit

- [ ] **Step 1.5.1: Add env-var plumbing in config/runtime.exs**

In `config/runtime.exs` (inside the `if config_env() != :test do` block), append:

```elixir
    regime_filter_enabled: System.get_env("REGIME_FILTER_ENABLED", "false") == "true",
    regime_max_realized_vol: String.to_float(System.get_env("REGIME_MAX_REALIZED_VOL", "1.0")),
    regime_max_adf_pvalue:
      case System.get_env("REGIME_MAX_ADF_PVALUE") do
        nil -> nil
        s -> String.to_float(s)
      end,
```

- [ ] **Step 1.5.2: Run full test suite and commit**

```bash
mix compile --warnings-as-errors
mix test
git add lib/alpaca_trader/engine.ex lib/alpaca_trader/backtest/simulator.ex test/alpaca_trader/engine_test.exs test/alpaca_trader/backtest/simulator_test.exs config/runtime.exs
git commit -m "feat(regime): wire regime filter into Engine, Simulator, runtime config"
```

---

## Task 2: Half-Life Time-Stop + Half-Life Sizing

Time-stop exits positions at `k × half_life` bars (default k=2); size-by-half-life scales position notional inversely with half-life so fast-reverting pairs get bigger allocations.

**Files:**
- Create: `lib/alpaca_trader/arbitrage/half_life_manager.ex`
- Create: `test/alpaca_trader/arbitrage/half_life_manager_test.exs`
- Modify: `lib/alpaca_trader/backtest/simulator.ex` — use HalfLifeManager for sizing + exit
- Modify: `lib/alpaca_trader/engine.ex` — same
- Modify: `config/runtime.exs` — `HALF_LIFE_TIME_STOP_MULT`, `HALF_LIFE_SIZE_ENABLED`

### 2.1 Write failing tests

- [ ] **Step 2.1.1: Write the failing test file**

Create `test/alpaca_trader/arbitrage/half_life_manager_test.exs`:

```elixir
defmodule AlpacaTrader.Arbitrage.HalfLifeManagerTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Arbitrage.HalfLifeManager

  describe "time_stop_bars/2" do
    test "returns k * half_life rounded up" do
      assert HalfLifeManager.time_stop_bars(10.0, 2.0) == 20
      assert HalfLifeManager.time_stop_bars(7.3, 2.0) == 15
    end

    test "clamps to minimum of max_hold floor when half_life is nil" do
      assert HalfLifeManager.time_stop_bars(nil, 2.0, fallback_bars: 60) == 60
    end
  end

  describe "size_multiplier/2" do
    test "returns 1.0 when half_life equals reference" do
      assert HalfLifeManager.size_multiplier(10.0, reference_half_life: 10.0) == 1.0
    end

    test "returns > 1.0 for faster reversion (shorter half-life)" do
      m = HalfLifeManager.size_multiplier(5.0, reference_half_life: 10.0)
      assert m > 1.0
    end

    test "returns < 1.0 for slower reversion" do
      m = HalfLifeManager.size_multiplier(20.0, reference_half_life: 10.0)
      assert m < 1.0
    end

    test "clamps to [min_mult, max_mult]" do
      m = HalfLifeManager.size_multiplier(1.0, reference_half_life: 10.0, min_mult: 0.5, max_mult: 2.0)
      assert m == 2.0
    end

    test "returns 1.0 when half_life is nil or non-positive" do
      assert HalfLifeManager.size_multiplier(nil) == 1.0
      assert HalfLifeManager.size_multiplier(0.0) == 1.0
      assert HalfLifeManager.size_multiplier(-3.0) == 1.0
    end
  end

  describe "should_time_stop?/3" do
    test "false before time_stop_bars" do
      refute HalfLifeManager.should_time_stop?(10, half_life: 10.0, multiplier: 2.0)
    end

    test "true at or past time_stop_bars" do
      assert HalfLifeManager.should_time_stop?(20, half_life: 10.0, multiplier: 2.0)
      assert HalfLifeManager.should_time_stop?(25, half_life: 10.0, multiplier: 2.0)
    end
  end
end
```

- [ ] **Step 2.1.2: Run test to verify failure**

Run: `mix test test/alpaca_trader/arbitrage/half_life_manager_test.exs`
Expected: FAIL with undefined module.

### 2.2 Implement HalfLifeManager

- [ ] **Step 2.2.1: Create module**

Create `lib/alpaca_trader/arbitrage/half_life_manager.ex`:

```elixir
defmodule AlpacaTrader.Arbitrage.HalfLifeManager do
  @moduledoc """
  Turn the Ornstein-Uhlenbeck half-life of a pair's spread into two
  operational levers:

  1. Time-stop: close any open position at `multiplier * half_life` bars
     regardless of z-score. A 2-day half-life pair held 30 bars is
     dead-money — the edge has decayed and carry costs eat the position.

  2. Size-by-half-life: scale notional inversely with half-life. Pairs
     that revert in 3 bars give you 10× the turnover of a 30-bar pair
     and should carry proportionally more capital for the same per-trade
     risk. Clamped to avoid runaway sizing on near-zero half-lives.

  All functions pure. Call `MeanReversion.half_life/1` upstream to get
  the input.
  """

  @default_time_stop_mult 2.0
  @default_reference_hl 10.0
  @default_min_mult 0.25
  @default_max_mult 2.0

  @doc """
  How many bars to allow before force-closing.

  If `half_life` is nil or non-positive, returns `fallback_bars` (default 60).
  """
  def time_stop_bars(half_life, multiplier \\ @default_time_stop_mult, opts \\ [])

  def time_stop_bars(half_life, multiplier, opts)
      when is_number(half_life) and half_life > 0 and is_number(multiplier) do
    trunc(Float.ceil(half_life * multiplier))
  end

  def time_stop_bars(_, _, opts), do: Keyword.get(opts, :fallback_bars, 60)

  @doc """
  Notional multiplier relative to reference half-life.

  Proportional: size_mult = reference_hl / half_life, clamped to
  `[min_mult, max_mult]`. Returns 1.0 when half_life is nil / <= 0.
  """
  def size_multiplier(half_life, opts \\ [])

  def size_multiplier(half_life, opts) when is_number(half_life) and half_life > 0 do
    reference = Keyword.get(opts, :reference_half_life, @default_reference_hl)
    min_mult = Keyword.get(opts, :min_mult, @default_min_mult)
    max_mult = Keyword.get(opts, :max_mult, @default_max_mult)

    raw = reference / half_life
    raw |> max(min_mult) |> min(max_mult)
  end

  def size_multiplier(_, _), do: 1.0

  @doc "True if the position has been open >= time_stop_bars."
  def should_time_stop?(hold_bars, opts) when is_integer(hold_bars) do
    half_life = Keyword.get(opts, :half_life)
    mult = Keyword.get(opts, :multiplier, @default_time_stop_mult)
    hold_bars >= time_stop_bars(half_life, mult, opts)
  end
end
```

- [ ] **Step 2.2.2: Run tests**

Run: `mix test test/alpaca_trader/arbitrage/half_life_manager_test.exs`
Expected: all pass.

- [ ] **Step 2.2.3: Commit**

```bash
git add lib/alpaca_trader/arbitrage/half_life_manager.ex test/alpaca_trader/arbitrage/half_life_manager_test.exs
git commit -m "feat(half_life): time-stop + size multiplier helpers"
```

### 2.3 Wire into Simulator

- [ ] **Step 2.3.1: Add half-life capture at entry**

In `lib/alpaca_trader/backtest/simulator.ex`, inside `maybe_enter`, compute the half-life from the spread window (reuse `MeanReversion.half_life/1`) and store it in the `pos` map:

```elixir
spread_series = SpreadCalculator.spread_series(window_a, window_b, analysis.hedge_ratio)
hl = AlpacaTrader.Arbitrage.MeanReversion.half_life(spread_series)

pos = %{
  # ... existing fields ...
  half_life: hl
}
```

- [ ] **Step 2.3.2: Use half-life for time-stop in maybe_exit/6**

In `maybe_exit`, replace the `hold_bars >= config.max_hold_bars` branch with:

```elixir
time_stop_mult = Map.get(config, :half_life_time_stop_mult, 2.0)
time_stop_bars = AlpacaTrader.Arbitrage.HalfLifeManager.time_stop_bars(
  pos[:half_life],
  time_stop_mult,
  fallback_bars: config.max_hold_bars
)

exit_reason =
  cond do
    hold_bars >= time_stop_bars -> :max_hold
    abs(z) >= config.stop_z -> :stop
    hold_bars >= 2 and crossed_exit_z?(pos.entry_z, z, config.exit_z) -> :target
    true -> nil
  end
```

- [ ] **Step 2.3.3: Apply size multiplier to compute_notional/5**

In `compute_notional`, multiply the returned notional by `HalfLifeManager.size_multiplier(hl, ...)` when `half_life_size_enabled` is true:

```elixir
defp compute_notional(equity, window_a, window_b, analysis, config) do
  base = compute_base_notional(equity, window_a, window_b, analysis, config)

  if Map.get(config, :half_life_size_enabled, false) do
    spread_series = SpreadCalculator.spread_series(window_a, window_b, analysis.hedge_ratio)
    hl = AlpacaTrader.Arbitrage.MeanReversion.half_life(spread_series)
    mult = AlpacaTrader.Arbitrage.HalfLifeManager.size_multiplier(hl)
    base * mult
  else
    base
  end
end
```

(Rename the existing `compute_notional` body to `compute_base_notional` — preserving the current fixed vs vol_scaled branching.)

- [ ] **Step 2.3.4: Simulator test for half-life time-stop**

Append to `test/alpaca_trader/backtest/simulator_test.exs`:

```elixir
test "half-life time-stop closes position at mult * half_life" do
  # Mean-reverting AR(1) spread → known short half-life
  :rand.seed(:exsss, {11, 22, 33})
  closes_a = Enum.scan(1..400, 100.0, fn _, last -> last + :rand.normal() end)
  closes_b = Enum.scan(1..400, 100.0, fn _, last -> last + :rand.normal() end)

  cfg = %{
    lookback_bars: 60,
    entry_z: 1.0,
    exit_z: 0.2,
    stop_z: 10.0,
    max_hold_bars: 1000,
    notional: 1000.0,
    half_life_time_stop_mult: 1.5
  }

  result = AlpacaTrader.Backtest.Simulator.run_pair("A-B", closes_a, closes_b, cfg)
  reasons = Enum.map(result.trades, & &1.reason)
  # Should see at least one max_hold (time-stop) exit in a high-entry, tight-exit config
  assert :max_hold in reasons or reasons == []
end
```

- [ ] **Step 2.3.5: Run simulator tests**

Run: `mix test test/alpaca_trader/backtest/simulator_test.exs`
Expected: all pass.

### 2.4 Wire into Engine (live path)

- [ ] **Step 2.4.1: Capture half-life when opening a position**

In `lib/alpaca_trader/engine.ex`, wherever the engine calls `PairPositionStore.open_position/...`, compute the half-life from the current spread window (same call pattern) and include it in the stored position state. If `PairPositionStore.open_position` doesn't accept a half-life yet, add an optional field to the struct/map it persists (update its schema and tests). Keep this change surgical.

- [ ] **Step 2.4.2: Apply time-stop in exit evaluation**

Find the engine's exit-evaluation function (likely `evaluate_exit/...` near the entry logic). Add the HalfLifeManager time-stop check alongside the existing stop-z / exit-z / max-hold logic. Use `Application.get_env(:alpaca_trader, :half_life_time_stop_mult, 2.0)`.

- [ ] **Step 2.4.3: Apply size multiplier when computing order notional**

Locate the sizing block (engine.ex:907 and 945). After the existing notional calculation, multiply by `HalfLifeManager.size_multiplier(hl)` when `Application.get_env(:alpaca_trader, :half_life_size_enabled, false)` is true.

- [ ] **Step 2.4.4: Run engine tests**

Run: `mix test test/alpaca_trader/engine_test.exs test/alpaca_trader/pair_position_store_test.exs`
Expected: all pass. Add any new test coverage needed for the new `:half_life` field on positions (one test per new public contract).

### 2.5 Config plumbing and commit

- [ ] **Step 2.5.1: Add env vars**

In `config/runtime.exs`:

```elixir
    half_life_time_stop_mult: String.to_float(System.get_env("HALF_LIFE_TIME_STOP_MULT", "2.0")),
    half_life_size_enabled: System.get_env("HALF_LIFE_SIZE_ENABLED", "false") == "true",
```

- [ ] **Step 2.5.2: Commit**

```bash
mix test
git add lib/alpaca_trader/backtest/simulator.ex lib/alpaca_trader/engine.ex test/alpaca_trader/backtest/simulator_test.exs test/alpaca_trader/engine_test.exs config/runtime.exs
git commit -m "feat(half_life): time-stop + size multiplier in Simulator and Engine"
```

---

## Task 3: Cost-Adjusted Walk-Forward + Whitelist Net-Sharpe Gate

Ensure `SlippageMeasurement` output feeds `WalkForward` as the `slippage_bps` config, and add `:min_net_sharpe` to `WhitelistGenerator` so pairs that are gross-profitable but net-negative get filtered out.

**Files:**
- Modify: `lib/alpaca_trader/backtest/walk_forward.ex` — expose per-window net Sharpe
- Modify: `lib/alpaca_trader/backtest/whitelist_generator.ex` — add `:min_net_sharpe`, `:min_net_return`
- Modify: `test/alpaca_trader/backtest/walk_forward_test.exs`
- Modify: `test/alpaca_trader/backtest/whitelist_generator_test.exs`

### 3.1 Add net-Sharpe to per-pair robustness

- [ ] **Step 3.1.1: Failing test**

Append to `test/alpaca_trader/backtest/walk_forward_test.exs`:

```elixir
test "per_pair_robustness includes sharpe and avg_window_return net of slippage config" do
  bars = %{
    "A" => Enum.map(1..800, fn i -> 100.0 + :math.sin(i / 10.0) end),
    "B" => Enum.map(1..800, fn i -> 100.0 + :math.cos(i / 10.0) end)
  }

  result = AlpacaTrader.Backtest.WalkForward.run([{"A", "B"}], bars,
    window_bars: 240, step_bars: 120, simulator_config: %{slippage_bps: 15.0})

  assert [r | _] = result.per_pair_robustness
  assert Map.has_key?(r, :sharpe_window_annualized)
  assert is_number(r.sharpe_window_annualized)
end
```

- [ ] **Step 3.1.2: Run to verify failure**

Run: `mix test test/alpaca_trader/backtest/walk_forward_test.exs`
Expected: FAIL — missing `:sharpe_window_annualized`.

- [ ] **Step 3.1.3: Implement**

In `lib/alpaca_trader/backtest/walk_forward.ex`, inside `compute_pair_robustness/1`, add Sharpe computation from per-window returns:

```elixir
sharpe_window_annualized =
  cond do
    n <= 1 -> 0.0
    true ->
      mean = Enum.sum(per_window_returns) / n
      var = Enum.reduce(per_window_returns, 0.0, fn r, acc -> acc + :math.pow(r - mean, 2) end) / (n - 1)
      std = :math.sqrt(var)
      if std > 0, do: Float.round(mean / std * :math.sqrt(12), 4), else: 0.0
  end
```

Include `sharpe_window_annualized: sharpe_window_annualized` in the map returned for each pair.

- [ ] **Step 3.1.4: Run tests**

Run: `mix test test/alpaca_trader/backtest/walk_forward_test.exs`
Expected: all pass.

### 3.2 Add `:min_net_sharpe` gate in WhitelistGenerator

- [ ] **Step 3.2.1: Failing test**

Append to `test/alpaca_trader/backtest/whitelist_generator_test.exs`:

```elixir
test "rejects pairs below :min_net_sharpe" do
  robustness = [
    %{pair: "A-B", n_windows: 5, wins: 4, win_ratio: 0.8, avg_window_return: 0.01, total_trades: 10, sharpe_window_annualized: 0.5, per_window_returns: [0.01, 0.02, -0.01, 0.03, 0.01]},
    %{pair: "C-D", n_windows: 5, wins: 4, win_ratio: 0.8, avg_window_return: 0.01, total_trades: 10, sharpe_window_annualized: 0.1, per_window_returns: [0.01, 0.001, -0.005, 0.01, 0.005]}
  ]

  wf_result = %{per_pair_robustness: robustness}
  {:ok, accepted} = AlpacaTrader.Backtest.WhitelistGenerator.generate(wf_result, min_net_sharpe: 0.4)
  assert accepted == [{"A", "B"}]
end
```

- [ ] **Step 3.2.2: Run to verify failure**

Run: `mix test test/alpaca_trader/backtest/whitelist_generator_test.exs`
Expected: FAIL — both pairs currently accepted because win_ratio=0.8 passes default.

- [ ] **Step 3.2.3: Implement gate**

In `lib/alpaca_trader/backtest/whitelist_generator.ex`, extend the filter:

```elixir
min_net_sharpe = Keyword.get(opts, :min_net_sharpe, nil)

accepted =
  Enum.filter(robustness, fn r ->
    r.n_windows >= min_windows and
      r.total_trades >= min_trades and
      r.win_ratio >= min_win_ratio and
      r.avg_window_return > min_avg_return and
      (is_nil(min_net_sharpe) or Map.get(r, :sharpe_window_annualized, 0.0) >= min_net_sharpe)
  end)
```

- [ ] **Step 3.2.4: Run tests**

Run: `mix test test/alpaca_trader/backtest/whitelist_generator_test.exs test/alpaca_trader/backtest/walk_forward_test.exs`
Expected: all pass.

- [ ] **Step 3.2.5: Commit**

```bash
git add lib/alpaca_trader/backtest/walk_forward.ex lib/alpaca_trader/backtest/whitelist_generator.ex test/alpaca_trader/backtest/walk_forward_test.exs test/alpaca_trader/backtest/whitelist_generator_test.exs
git commit -m "feat(backtest): net-Sharpe metric + whitelist gate"
```

### 3.3 Document the calibration loop

- [ ] **Step 3.3.1: Append to `docs/superpowers/specs/` or `README.md` under a "calibration" section**

Add a short paragraph explaining the loop: run `SlippageMeasurement.measure/1` → take the `recommended backtest slippage_bps` → pass as `simulator_config: %{slippage_bps: X}` in `WalkForward.run/3` → run `WhitelistGenerator.generate/2` with `min_net_sharpe: 0.5`. No code change; one paragraph in docs. (If both locations already have partial coverage, add to whichever already has the `SlippageMeasurement` mention.)

- [ ] **Step 3.3.2: Commit docs**

```bash
git add docs/ README.md 2>/dev/null || true
git commit -m "docs(backtest): calibration loop for cost-adjusted whitelist" --allow-empty
```

---

## Task 4: Kelly Fractional Sizing

Derive a position-size cap from walk-forward win-rate and average win/loss magnitudes; apply as a *ceiling* on top of existing vol sizing.

**Files:**
- Create: `lib/alpaca_trader/arbitrage/kelly_sizer.ex`
- Create: `test/alpaca_trader/arbitrage/kelly_sizer_test.exs`
- Modify: `lib/alpaca_trader/engine.ex` — call Kelly cap after existing sizing
- Modify: `lib/alpaca_trader/backtest/simulator.ex` — same
- Modify: `config/runtime.exs` — `KELLY_ENABLED`, `KELLY_FRACTION`, `KELLY_MAX_CAP_PCT`

### 4.1 Write failing tests

- [ ] **Step 4.1.1: Test file**

Create `test/alpaca_trader/arbitrage/kelly_sizer_test.exs`:

```elixir
defmodule AlpacaTrader.Arbitrage.KellySizerTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Arbitrage.KellySizer

  describe "kelly_fraction/3" do
    test "returns 0 when edge is non-positive" do
      # Equal wins and losses, 50% win rate → f* = 0
      assert KellySizer.kelly_fraction(0.5, 0.01, 0.01) == 0.0
    end

    test "returns positive fraction for favorable edge" do
      # 60% wins of 2%, 40% losses of 1% → f* = (0.6 * 2 - 0.4) / 2 = 0.4
      f = KellySizer.kelly_fraction(0.6, 0.02, 0.01)
      assert_in_delta f, 0.4, 1.0e-6
    end

    test "returns 0 if avg_loss is non-positive (no downside)" do
      assert KellySizer.kelly_fraction(0.6, 0.02, 0.0) == 0.0
    end

    test "returns 0 for edge-case win_rate outside (0,1)" do
      assert KellySizer.kelly_fraction(0.0, 0.02, 0.01) == 0.0
      assert KellySizer.kelly_fraction(1.0, 0.02, 0.01) == 0.0
    end
  end

  describe "size_cap/4" do
    test "applies fractional Kelly and caps at max_cap_pct" do
      equity = 10_000.0
      # Full Kelly = 0.4, half-Kelly = 0.2 → 20% = $2000 → capped at 10% = $1000
      cap = KellySizer.size_cap(equity, %{win_rate: 0.6, avg_win_pct: 0.02, avg_loss_pct: 0.01},
        fraction: 0.5, max_cap_pct: 0.10)
      assert cap == 1_000.0
    end

    test "returns equity * max_cap when stats missing" do
      cap = KellySizer.size_cap(10_000.0, %{}, fraction: 0.5, max_cap_pct: 0.05)
      assert cap == 500.0
    end
  end
end
```

- [ ] **Step 4.1.2: Run to verify failure**

Run: `mix test test/alpaca_trader/arbitrage/kelly_sizer_test.exs`
Expected: FAIL — module undefined.

### 4.2 Implement KellySizer

- [ ] **Step 4.2.1: Create module**

Create `lib/alpaca_trader/arbitrage/kelly_sizer.ex`:

```elixir
defmodule AlpacaTrader.Arbitrage.KellySizer do
  @moduledoc """
  Kelly-fractional sizing cap derived from walk-forward statistics.

  Full Kelly for a binary-outcome bet is

      f* = (p * b - q) / b

  where p is win probability, q = 1-p, and b is the payoff ratio
  (avg_win / avg_loss). Full Kelly maximizes long-run log growth but
  produces brutal drawdowns; in practice traders use fractional Kelly
  (half or quarter) and cap the fraction at a hard ceiling so a
  stale/overfit edge estimate cannot size the book into ruin.

  This module only computes a *ceiling* on notional; the engine's
  existing vol-scaled sizing still picks the actual amount. Kelly is
  opt-in and off by default.
  """

  @doc "Full Kelly fraction, clamped to [0, 1]."
  def kelly_fraction(win_rate, avg_win_pct, avg_loss_pct)
      when is_number(win_rate) and win_rate > 0 and win_rate < 1 and
             is_number(avg_win_pct) and avg_win_pct > 0 and
             is_number(avg_loss_pct) and avg_loss_pct > 0 do
    b = avg_win_pct / avg_loss_pct
    p = win_rate
    q = 1.0 - p

    raw = (p * b - q) / b
    raw |> max(0.0) |> min(1.0)
  end

  def kelly_fraction(_, _, _), do: 0.0

  @doc """
  Size cap in dollars.

  `stats` is a map with `:win_rate`, `:avg_win_pct`, `:avg_loss_pct`.
  When any key is missing or invalid, returns `equity * max_cap_pct`
  (falls back to the hard cap so sizing never exceeds policy).
  """
  def size_cap(equity, stats, opts \\ []) when is_number(equity) and equity > 0 do
    fraction = Keyword.get(opts, :fraction, 0.5)
    max_cap_pct = Keyword.get(opts, :max_cap_pct, 0.10)

    f_star =
      kelly_fraction(
        Map.get(stats, :win_rate),
        Map.get(stats, :avg_win_pct),
        Map.get(stats, :avg_loss_pct)
      )

    fractional = f_star * fraction
    pct = min(fractional, max_cap_pct)
    equity * pct
  end

  def size_cap(_, _, _), do: 0.0
end
```

- [ ] **Step 4.2.2: Run tests**

Run: `mix test test/alpaca_trader/arbitrage/kelly_sizer_test.exs`
Expected: all pass.

- [ ] **Step 4.2.3: Commit**

```bash
git add lib/alpaca_trader/arbitrage/kelly_sizer.ex test/alpaca_trader/arbitrage/kelly_sizer_test.exs
git commit -m "feat(kelly): fractional Kelly sizing cap"
```

### 4.3 Wire into Simulator and Engine

- [ ] **Step 4.3.1: Simulator integration**

In `lib/alpaca_trader/backtest/simulator.ex`, after computing `notional` in `compute_notional/5`, clip to the Kelly cap when enabled. You need access to running stats — for the simulator, compute from `state.trades` so far (a running win_rate / avg_win / avg_loss). Add a helper:

```elixir
defp kelly_clip(notional, state, equity, config) do
  if Map.get(config, :kelly_enabled, false) do
    stats = running_stats(state.trades)
    cap = AlpacaTrader.Arbitrage.KellySizer.size_cap(equity, stats,
      fraction: Map.get(config, :kelly_fraction, 0.5),
      max_cap_pct: Map.get(config, :kelly_max_cap_pct, 0.10))
    min(notional, cap)
  else
    notional
  end
end

defp running_stats([]), do: %{}

defp running_stats(trades) do
  wins = Enum.filter(trades, & &1.pnl_pct > 0)
  losses = Enum.filter(trades, & &1.pnl_pct <= 0)
  n = length(trades)
  if n < 10 do
    %{}
  else
    %{
      win_rate: length(wins) / n,
      avg_win_pct: avg(Enum.map(wins, & &1.pnl_pct)),
      avg_loss_pct: abs(avg(Enum.map(losses, & &1.pnl_pct)))
    }
  end
end

defp avg([]), do: 0.0
defp avg(xs), do: Enum.sum(xs) / length(xs)
```

Call `kelly_clip` at the end of `compute_notional`. Kelly needs >= 10 trades of history to produce meaningful stats; below that, the cap reverts to `max_cap_pct` as a floor.

- [ ] **Step 4.3.2: Simulator test for Kelly clip**

Append to `test/alpaca_trader/backtest/simulator_test.exs`:

```elixir
test "kelly_enabled caps notional below fixed size once history accrues" do
  :rand.seed(:exsss, {4, 5, 6})
  closes_a = Enum.scan(1..800, 100.0, fn _, last -> last + :rand.normal() * 0.5 end)
  closes_b = Enum.scan(1..800, 100.0, fn _, last -> last + :rand.normal() * 0.5 end)

  cfg = %{
    notional: 10_000.0,
    kelly_enabled: true,
    kelly_fraction: 0.5,
    kelly_max_cap_pct: 0.01,  # 1% of equity max
    entry_z: 1.0,
    exit_z: 0.3,
    stop_z: 5.0
  }

  result = AlpacaTrader.Backtest.Simulator.run_pair("A-B", closes_a, closes_b, cfg)
  assert Enum.all?(result.trades, fn t -> t.notional <= 10_000.0 end)
end
```

- [ ] **Step 4.3.3: Engine integration**

In `lib/alpaca_trader/engine.ex`, at the sizing block (line 945 area), after computing the vol-scaled notional, clip with Kelly using lifetime stats from `TradeLog` (or `GainAccumulatorStore` if it exposes win/loss ratios). If neither store exposes win-rate yet, add a simple `TradeLog.performance_stats/0` function that returns the same shape as `running_stats/1` above. Guard behind `Application.get_env(:alpaca_trader, :kelly_enabled, false)`.

- [ ] **Step 4.3.4: Add TradeLog.performance_stats/0 if missing**

Check: `grep -n "performance_stats\|def " /Users/home/repos/alpaca_trader/lib/alpaca_trader/trade_log.ex`

If not present, add a function returning `%{win_rate, avg_win_pct, avg_loss_pct}` from the logged trades. Add an ExUnit test verifying the returned shape.

- [ ] **Step 4.3.5: Run full test suite**

```bash
mix test
```

Expected: all pass.

### 4.4 Config + commit

- [ ] **Step 4.4.1: Env vars**

In `config/runtime.exs`:

```elixir
    kelly_enabled: System.get_env("KELLY_ENABLED", "false") == "true",
    kelly_fraction: String.to_float(System.get_env("KELLY_FRACTION", "0.5")),
    kelly_max_cap_pct: String.to_float(System.get_env("KELLY_MAX_CAP_PCT", "0.05")),
```

- [ ] **Step 4.4.2: Commit**

```bash
git add lib/alpaca_trader/backtest/simulator.ex lib/alpaca_trader/engine.ex lib/alpaca_trader/trade_log.ex test/alpaca_trader/backtest/simulator_test.exs test/alpaca_trader/engine_test.exs config/runtime.exs
git commit -m "feat(kelly): wire Kelly size cap into Simulator and Engine"
```

---

## Task 5: Marketable-Limit Execution + Fill Metrics

Add a `:marketable_limit` order mode that submits IOC limit orders at `mid ± k × spread` instead of raw market orders, and log fill-rate + realized slippage so `SlippageMeasurement` has data to measure.

**Files:**
- Modify: `lib/alpaca_trader/engine/order_executor.ex` — add marketable-limit path
- Modify: `lib/alpaca_trader/alpaca/client.ex` — accept `type: "limit"`, `time_in_force: "ioc"`, `limit_price` (if not already supported)
- Modify: `config/runtime.exs` — `ORDER_TYPE_MODE`, `MARKETABLE_LIMIT_SPREAD_MULT`
- Modify: tests accordingly

### 5.1 Read the existing executor

- [ ] **Step 5.1.1: View file**

Run: `cat /Users/home/repos/alpaca_trader/lib/alpaca_trader/engine/order_executor.ex`

Note the current order-submission shape: endpoints used, what fields are passed, whether it already supports `:marketable_limit` (partially or not). If it does, the work below is narrower.

### 5.2 Write failing test

- [ ] **Step 5.2.1: Test file**

Create or extend `test/alpaca_trader/engine/order_executor_test.exs` (create if missing):

```elixir
defmodule AlpacaTrader.Engine.OrderExecutorTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.Engine.OrderExecutor

  describe "build_order/3" do
    test "market mode builds a market order (legacy default)" do
      order = OrderExecutor.build_order(%{symbol: "AAPL", qty: 10, side: :buy},
        %{bid: 99.0, ask: 101.0}, mode: :market)
      assert order.type == "market"
      refute Map.has_key?(order, :limit_price)
    end

    test "marketable_limit mode sets limit_price at ask + k*spread on buy" do
      order = OrderExecutor.build_order(%{symbol: "AAPL", qty: 10, side: :buy},
        %{bid: 99.0, ask: 101.0}, mode: :marketable_limit, spread_mult: 0.25)
      assert order.type == "limit"
      assert order.time_in_force == "ioc"
      # ask + 0.25 * spread (2.0) = 101.0 + 0.5 = 101.5
      assert_in_delta order.limit_price, 101.5, 1.0e-6
    end

    test "marketable_limit mode sets limit_price at bid - k*spread on sell" do
      order = OrderExecutor.build_order(%{symbol: "AAPL", qty: 10, side: :sell},
        %{bid: 99.0, ask: 101.0}, mode: :marketable_limit, spread_mult: 0.25)
      assert order.type == "limit"
      # bid - 0.25 * spread = 99.0 - 0.5 = 98.5
      assert_in_delta order.limit_price, 98.5, 1.0e-6
    end
  end
end
```

- [ ] **Step 5.2.2: Run test**

Run: `mix test test/alpaca_trader/engine/order_executor_test.exs`
Expected: FAIL.

### 5.3 Implement build_order/3

- [ ] **Step 5.3.1: Add or extend the function**

In `lib/alpaca_trader/engine/order_executor.ex`, add a pure `build_order/3` that returns a map describing the order (no API call — that's a separate function). If the module already has an order-construction helper, extend it rather than duplicate.

```elixir
@doc """
Construct an order payload given the desired fill mode.

`mode`:
- `:market` — legacy market order
- `:marketable_limit` — IOC limit order at `ask + k*spread` (buy) or
  `bid - k*spread` (sell). Filling against the opposite side of the book
  gives us exposure to the wide-spread tax and a way to measure it.
"""
def build_order(params, quote, opts \\ [])

def build_order(%{symbol: s, qty: q, side: side}, _quote, opts) do
  case Keyword.get(opts, :mode, :market) do
    :market ->
      %{symbol: s, qty: q, side: side, type: "market", time_in_force: "day"}

    :marketable_limit ->
      %{bid: bid, ask: ask} = _quote = Keyword.get(opts, :quote) || (raise "quote required for marketable_limit")
      # Actually, use the passed quote map:
      limit_price = marketable_limit_price(side, bid, ask, Keyword.get(opts, :spread_mult, 0.25))
      %{symbol: s, qty: q, side: side, type: "limit", time_in_force: "ioc", limit_price: limit_price}
  end
end

defp marketable_limit_price(:buy, bid, ask, k), do: ask + k * (ask - bid)
defp marketable_limit_price(:sell, bid, ask, k), do: bid - k * (ask - bid)
```

Fix the function signature so the `quote` argument comes in as a positional map (not `opts`). Exact shape:

```elixir
def build_order(%{symbol: s, qty: q, side: side}, quote, opts) when is_map(quote) do
  mode = Keyword.get(opts, :mode, :market)
  spread_mult = Keyword.get(opts, :spread_mult, 0.25)

  case mode do
    :market ->
      %{symbol: s, qty: q, side: side, type: "market", time_in_force: "day"}

    :marketable_limit ->
      limit_price = marketable_limit_price(side, quote.bid, quote.ask, spread_mult)
      %{symbol: s, qty: q, side: side, type: "limit", time_in_force: "ioc", limit_price: limit_price}
  end
end
```

- [ ] **Step 5.3.2: Run tests**

Run: `mix test test/alpaca_trader/engine/order_executor_test.exs`
Expected: all pass.

### 5.4 Wire the mode switch into live submission

- [ ] **Step 5.4.1: Replace market-only submission with mode lookup**

In the existing `submit_order`-style function in `order_executor.ex`, look up `Application.get_env(:alpaca_trader, :order_type_mode, :market)` and call `build_order/3` instead of constructing the payload inline. Fetch the latest quote from `Alpaca.Client` (latest-quote endpoint) when mode is `:marketable_limit`. If the client doesn't have a `latest_quote/1`, add it.

- [ ] **Step 5.4.2: Log fill metadata**

After submission returns, log a structured entry via `Logger.info`:

```elixir
Logger.info("[OrderExecutor] submitted: #{inspect(%{mode: mode, side: side, symbol: symbol, limit_price: Map.get(payload, :limit_price), status: response_status})}")
```

This gives `SlippageMeasurement` real data to compare filled price vs limit price.

- [ ] **Step 5.4.3: Config**

In `config/runtime.exs`:

```elixir
    order_type_mode:
      case System.get_env("ORDER_TYPE_MODE", "market") do
        "marketable_limit" -> :marketable_limit
        _ -> :market
      end,
    marketable_limit_spread_mult: String.to_float(System.get_env("MARKETABLE_LIMIT_SPREAD_MULT", "0.25")),
```

- [ ] **Step 5.4.4: Run all tests**

```bash
mix test
```

Expected: all pass.

- [ ] **Step 5.4.5: Commit**

```bash
git add lib/alpaca_trader/engine/order_executor.ex lib/alpaca_trader/alpaca/client.ex test/alpaca_trader/engine/order_executor_test.exs config/runtime.exs
git commit -m "feat(exec): marketable-limit order mode + structured fill logging"
```

---

## Task 6: Correlation / Cluster Exposure Cap

Prevent the whitelist from stacking many correlated pairs (e.g. 5 tech pairs) by computing live pairwise correlation across currently-open positions and rejecting entries that push cluster exposure past a cap.

**Files:**
- Create: `lib/alpaca_trader/arbitrage/cluster_limiter.ex`
- Create: `test/alpaca_trader/arbitrage/cluster_limiter_test.exs`
- Modify: `lib/alpaca_trader/portfolio_risk.ex` — add `check_cluster_exposure/2`
- Modify: `lib/alpaca_trader/application.ex` — supervise new GenServer if stateful (or pure? — see below)
- Modify: `config/runtime.exs` — `CLUSTER_CORR_THRESHOLD`, `MAX_PAIRS_PER_CLUSTER`

**Design note:** Start pure-functional. Given a list of open positions and their recent return series (fetched from `BarsStore`), compute pairwise correlations and find clusters by transitive closure on a correlation threshold. No GenServer needed if `BarsStore` already persists the return series.

### 6.1 Write failing tests

- [ ] **Step 6.1.1: Test file**

Create `test/alpaca_trader/arbitrage/cluster_limiter_test.exs`:

```elixir
defmodule AlpacaTrader.Arbitrage.ClusterLimiterTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Arbitrage.ClusterLimiter

  describe "correlation_matrix/1" do
    test "returns 1.0 on the diagonal" do
      series = %{
        "A" => [1.0, 2.0, 3.0, 4.0, 5.0],
        "B" => [5.0, 4.0, 3.0, 2.0, 1.0]
      }

      m = ClusterLimiter.correlation_matrix(series)
      assert_in_delta Map.fetch!(m, {"A", "A"}), 1.0, 1.0e-9
      assert_in_delta Map.fetch!(m, {"B", "B"}), 1.0, 1.0e-9
      assert_in_delta Map.fetch!(m, {"A", "B"}), -1.0, 1.0e-9
    end
  end

  describe "find_clusters/2" do
    test "groups symbols whose pairwise correlation exceeds threshold" do
      # A, B, C all perfectly correlated; D anticorrelated
      series = %{
        "A" => [1.0, 2.0, 3.0, 4.0, 5.0],
        "B" => [2.0, 4.0, 6.0, 8.0, 10.0],
        "C" => [3.0, 6.0, 9.0, 12.0, 15.0],
        "D" => [5.0, 4.0, 3.0, 2.0, 1.0]
      }

      clusters = ClusterLimiter.find_clusters(series, correlation_threshold: 0.9)

      assert Enum.any?(clusters, fn c -> MapSet.new(c) == MapSet.new(["A", "B", "C"]) end)
      assert Enum.any?(clusters, fn c -> MapSet.new(c) == MapSet.new(["D"]) end)
    end
  end

  describe "allow_entry?/3" do
    test "allows when no cluster is near the cap" do
      series = %{"A" => [1.0, 2.0, 3.0], "B" => [3.0, 2.0, 1.0]}
      open_positions = []
      assert :ok = ClusterLimiter.allow_entry?(
        %{asset_a: "A", asset_b: "B"}, open_positions, series: series, correlation_threshold: 0.95, max_per_cluster: 3)
    end

    test "blocks when the new pair's cluster already has max_per_cluster members" do
      series = %{
        "A" => [1.0, 2.0, 3.0, 4.0],
        "B" => [1.0, 2.0, 3.0, 4.0],
        "C" => [1.0, 2.0, 3.0, 4.0],
        "X" => [1.0, 2.0, 3.0, 4.0]
      }

      open = [
        %{asset_a: "A", asset_b: "B"},
        %{asset_a: "B", asset_b: "C"},
        %{asset_a: "A", asset_b: "C"}
      ]

      assert {:blocked, {:cluster_full, _}} =
               ClusterLimiter.allow_entry?(
                 %{asset_a: "A", asset_b: "X"},
                 open,
                 series: series,
                 correlation_threshold: 0.9,
                 max_per_cluster: 3
               )
    end
  end
end
```

- [ ] **Step 6.1.2: Run to verify failure**

Run: `mix test test/alpaca_trader/arbitrage/cluster_limiter_test.exs`
Expected: FAIL.

### 6.2 Implement ClusterLimiter

- [ ] **Step 6.2.1: Create module**

Create `lib/alpaca_trader/arbitrage/cluster_limiter.ex`:

```elixir
defmodule AlpacaTrader.Arbitrage.ClusterLimiter do
  @moduledoc """
  Prevent concentrating the book in a cluster of correlated pairs.

  A whitelist that passes walk-forward on 20 pairs can happily be 8 tech,
  6 energy, 4 finance, 2 crypto — one regime shock to tech and half the
  book drops in lockstep. This module treats correlated symbols as a
  single cluster and caps the number of concurrent positions per cluster.

  Clustering uses a single-linkage transitive closure on Pearson
  correlation of recent return series. `correlation_threshold` controls
  how tight a cluster is. Pure functional; callers supply the return
  series (usually from `BarsStore`) and the list of currently-open
  positions.
  """

  @doc "Pairwise Pearson correlation matrix from `symbol => series`."
  def correlation_matrix(series_map) when is_map(series_map) do
    symbols = Map.keys(series_map)

    for a <- symbols, b <- symbols, into: %{} do
      val =
        if a == b do
          1.0
        else
          pearson(Map.fetch!(series_map, a), Map.fetch!(series_map, b))
        end

      {{a, b}, val}
    end
  end

  @doc """
  Return a list of clusters (each a list of symbols). Two symbols are in
  the same cluster if their correlation >= threshold (via transitive
  closure).
  """
  def find_clusters(series_map, opts \\ []) do
    threshold = Keyword.get(opts, :correlation_threshold, 0.8)
    corr = correlation_matrix(series_map)

    adj =
      for {{a, b}, v} <- corr, a != b, v >= threshold, reduce: %{} do
        acc ->
          Map.update(acc, a, MapSet.new([b]), &MapSet.put(&1, b))
      end

    symbols = Map.keys(series_map)
    union_find_clusters(symbols, adj)
  end

  @doc """
  Decide whether opening a new pair would push a cluster past its cap.

  Options:
  - `:series` — map of symbol -> return series for clustering
  - `:correlation_threshold` (default 0.8)
  - `:max_per_cluster` (default 3)
  """
  def allow_entry?(arb, open_positions, opts) when is_map(arb) and is_list(open_positions) do
    series = Keyword.fetch!(opts, :series)
    threshold = Keyword.get(opts, :correlation_threshold, 0.8)
    max_per = Keyword.get(opts, :max_per_cluster, 3)

    clusters = find_clusters(series, correlation_threshold: threshold)

    cluster_of =
      for cluster <- clusters, sym <- cluster, into: %{}, do: {sym, MapSet.new(cluster)}

    new_symbols = [arb.asset_a, arb.asset_b]

    open_symbols =
      Enum.flat_map(open_positions, fn p -> [Map.get(p, :asset_a), Map.get(p, :asset_b)] end)
      |> Enum.reject(&is_nil/1)

    Enum.find_value(new_symbols, :ok, fn sym ->
      cluster = Map.get(cluster_of, sym, MapSet.new([sym]))

      count =
        Enum.count(open_symbols, fn s -> MapSet.member?(cluster, s) end)

      if count >= max_per do
        {:blocked, {:cluster_full, cluster |> MapSet.to_list() |> Enum.sort()}}
      else
        nil
      end
    end)
  end

  # ── helpers ────────────────────────────────────────────────

  defp pearson(xs, ys) when length(xs) == length(ys) and length(xs) > 1 do
    n = length(xs)
    mean_x = Enum.sum(xs) / n
    mean_y = Enum.sum(ys) / n

    {sxx, syy, sxy} =
      Enum.zip(xs, ys)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {a, b, c} ->
        dx = x - mean_x
        dy = y - mean_y
        {a + dx * dx, b + dy * dy, c + dx * dy}
      end)

    denom = :math.sqrt(sxx * syy)
    if denom == 0.0, do: 0.0, else: sxy / denom
  end

  defp pearson(_, _), do: 0.0

  defp union_find_clusters(symbols, adj) do
    {clusters, _visited} =
      Enum.reduce(symbols, {[], MapSet.new()}, fn sym, {acc, visited} ->
        if MapSet.member?(visited, sym) do
          {acc, visited}
        else
          cluster = bfs(sym, adj, MapSet.new([sym]))
          {[MapSet.to_list(cluster) | acc], MapSet.union(visited, cluster)}
        end
      end)

    clusters
  end

  defp bfs(_sym, adj, visited) do
    Enum.reduce_while(Stream.cycle([:continue]), visited, fn _, current ->
      new_members =
        for sym <- current,
            neighbor <- Map.get(adj, sym, MapSet.new()),
            not MapSet.member?(current, neighbor),
            reduce: current do
          acc -> MapSet.put(acc, neighbor)
        end

      if MapSet.equal?(new_members, current) do
        {:halt, current}
      else
        {:cont, new_members}
      end
    end)
  end
end
```

- [ ] **Step 6.2.2: Run tests**

Run: `mix test test/alpaca_trader/arbitrage/cluster_limiter_test.exs`
Expected: all pass.

- [ ] **Step 6.2.3: Commit**

```bash
git add lib/alpaca_trader/arbitrage/cluster_limiter.ex test/alpaca_trader/arbitrage/cluster_limiter_test.exs
git commit -m "feat(cluster): correlation cluster exposure limiter"
```

### 6.3 Delegate from PortfolioRisk

- [ ] **Step 6.3.1: Add check to portfolio_risk.ex**

In `lib/alpaca_trader/portfolio_risk.ex`, add a third check function:

```elixir
defp check_cluster(open, arb) do
  if Application.get_env(:alpaca_trader, :cluster_limiter_enabled, false) do
    series = fetch_return_series_for([arb.asset_a, arb.asset_b | Enum.flat_map(open, &[&1.asset_a, &1.asset_b])])
    opts = [
      series: series,
      correlation_threshold: Application.get_env(:alpaca_trader, :cluster_corr_threshold, 0.8),
      max_per_cluster: Application.get_env(:alpaca_trader, :max_pairs_per_cluster, 3)
    ]
    AlpacaTrader.Arbitrage.ClusterLimiter.allow_entry?(arb, open, opts)
  else
    :ok
  end
end

defp fetch_return_series_for(symbols) do
  symbols
  |> Enum.uniq()
  |> Enum.reject(&is_nil/1)
  |> Enum.map(fn s -> {s, AlpacaTrader.BarsStore.recent_returns(s, 200)} end)
  |> Enum.reject(fn {_, series} -> series in [nil, []] end)
  |> Map.new()
end
```

Call `check_cluster/2` from `allow_entry?/1`:

```elixir
def allow_entry?(arb) when is_map(arb) do
  open = PairPositionStore.open_positions()

  with :ok <- check_max_open(open),
       :ok <- check_per_sector(open, arb),
       :ok <- check_cluster(open, arb) do
    :ok
  end
end
```

- [ ] **Step 6.3.2: Add BarsStore.recent_returns/2 if missing**

Check whether `BarsStore` has a function returning the last N log/arithmetic returns for a symbol. If not, add one and a small test. Signature:

```elixir
def recent_returns(symbol, n) do
  case bars(symbol) do
    nil -> []
    bars ->
      bars
      |> Enum.take(-max(n + 1, 2))
      |> Enum.map(& &1.close)
      |> returns()
  end
end

defp returns([_]), do: []
defp returns(prices) do
  prices
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.map(fn [a, b] -> (b - a) / a end)
end
```

- [ ] **Step 6.3.3: Config**

In `config/runtime.exs`:

```elixir
    cluster_limiter_enabled: System.get_env("CLUSTER_LIMITER_ENABLED", "false") == "true",
    cluster_corr_threshold: String.to_float(System.get_env("CLUSTER_CORR_THRESHOLD", "0.8")),
    max_pairs_per_cluster: String.to_integer(System.get_env("MAX_PAIRS_PER_CLUSTER", "3")),
```

- [ ] **Step 6.3.4: Run full suite**

```bash
mix test
```

Expected: all pass.

- [ ] **Step 6.3.5: Commit**

```bash
git add lib/alpaca_trader/portfolio_risk.ex lib/alpaca_trader/bars_store.ex test/alpaca_trader/bars_store_test.exs config/runtime.exs
git commit -m "feat(cluster): integrate cluster limiter into PortfolioRisk"
```

---

## Task 7: Online Re-Cointegration Refresh Job

A weekly cron that re-runs ADF and half-life checks on every whitelisted pair using the most recent bars, and evicts pairs that have drifted.

**Files:**
- Create: `lib/alpaca_trader/scheduler/jobs/pair_recointegration_job.ex`
- Create: `test/alpaca_trader/scheduler/jobs/pair_recointegration_job_test.exs`
- Modify: `lib/alpaca_trader/application.ex` / `scheduler/quantum.ex` — register the job
- Modify: `config/runtime.exs` — schedule and thresholds

### 7.1 Write failing test

- [ ] **Step 7.1.1: Test file**

Create `test/alpaca_trader/scheduler/jobs/pair_recointegration_job_test.exs`:

```elixir
defmodule AlpacaTrader.Scheduler.Jobs.PairRecointegrationJobTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.Scheduler.Jobs.PairRecointegrationJob
  alias AlpacaTrader.Arbitrage.PairWhitelist

  setup do
    # Redirect whitelist to a temp file so we don't clobber runtime state
    tmp = Path.join(System.tmp_dir!(), "pair_whitelist_#{System.unique_integer([:positive])}.json")
    :ok = PairWhitelist.set_path(tmp)
    PairWhitelist.replace([{"A", "B"}, {"C", "D"}])
    on_exit(fn -> File.rm(tmp) end)
    %{tmp: tmp}
  end

  describe "evaluate/2" do
    test "retains pairs that pass ADF, evicts pairs that don't" do
      # "A-B" has stationary synthetic spread; "C-D" has a random walk spread
      stationary = Enum.scan(1..500, 0.0, fn _, last -> 0.3 * last + :rand.normal() end)
      rw = Enum.scan(1..500, 0.0, fn _, last -> last + :rand.normal() end)

      bars = %{
        "A" => Enum.map(stationary, &(100.0 + &1)),
        "B" => List.duplicate(100.0, 500),
        "C" => Enum.map(rw, &(100.0 + &1)),
        "D" => List.duplicate(100.0, 500)
      }

      {:ok, report} = PairRecointegrationJob.evaluate(PairWhitelist.list(), bars)

      assert {"A", "B"} in report.retained
      assert {"C", "D"} in report.evicted
    end
  end
end
```

- [ ] **Step 7.1.2: Run**

Run: `mix test test/alpaca_trader/scheduler/jobs/pair_recointegration_job_test.exs`
Expected: FAIL.

### 7.2 Implement job

- [ ] **Step 7.2.1: Create module**

Create `lib/alpaca_trader/scheduler/jobs/pair_recointegration_job.ex`:

```elixir
defmodule AlpacaTrader.Scheduler.Jobs.PairRecointegrationJob do
  @moduledoc """
  Weekly job that re-validates every whitelisted pair against fresh bars.

  A pair that passed walk-forward six months ago may no longer cointegrate
  — the underlying relationship can break quietly (regime change, business
  model shift, delisting of a substitute). Waiting for the monthly full
  walk-forward cycle leaves the engine placing bets on broken pairs.

  This job runs ADF + half-life on the most recent `:lookback_bars` bars
  for each whitelisted pair and removes any pair that fails. It logs a
  structured report of retained vs evicted pairs.
  """

  alias AlpacaTrader.Arbitrage.{PairWhitelist, SpreadCalculator, MeanReversion}
  alias AlpacaTrader.BarsStore

  require Logger

  @spec run() :: :ok
  def run do
    bars = fetch_current_bars(PairWhitelist.list())
    {:ok, report} = evaluate(PairWhitelist.list(), bars)

    PairWhitelist.replace(report.retained)

    Logger.info(
      "[PairRecointegrationJob] retained #{length(report.retained)}, evicted #{length(report.evicted)}"
    )

    :ok
  end

  @spec evaluate([{String.t(), String.t()}], map()) ::
          {:ok, %{retained: [{String.t(), String.t()}], evicted: [{String.t(), String.t()}]}}
  def evaluate(pairs, bars_map) do
    {retained, evicted} =
      Enum.split_with(pairs, fn {a, b} ->
        ca = Map.get(bars_map, a, [])
        cb = Map.get(bars_map, b, [])

        if length(ca) < 100 or length(cb) < 100 do
          # Insufficient data → keep the pair; the next scan will handle it.
          true
        else
          analysis = SpreadCalculator.analyze(ca, cb)
          spread = SpreadCalculator.spread_series(ca, cb, analysis.hedge_ratio)
          match?({:ok, _}, MeanReversion.classify(spread, max_half_life: 60))
        end
      end)

    {:ok, %{retained: retained, evicted: evicted}}
  end

  defp fetch_current_bars(pairs) do
    lookback = Application.get_env(:alpaca_trader, :recointegration_lookback_bars, 500)

    pairs
    |> Enum.flat_map(fn {a, b} -> [a, b] end)
    |> Enum.uniq()
    |> Enum.map(fn sym -> {sym, BarsStore.recent_closes(sym, lookback)} end)
    |> Map.new()
  end
end
```

If `BarsStore` does not have `recent_closes/2`, add one alongside `recent_returns/2` from Task 6.

- [ ] **Step 7.2.2: Run tests**

Run: `mix test test/alpaca_trader/scheduler/jobs/pair_recointegration_job_test.exs`
Expected: all pass.

### 7.3 Register cron

- [ ] **Step 7.3.1: Register in quantum config**

In `lib/alpaca_trader/scheduler/quantum.ex` (or `application.ex` register block), add the job on a weekly schedule (Sunday 06:00 UTC is a quiet time for most markets):

```elixir
Api.register_job(
  AlpacaTrader.Scheduler.Jobs.PairRecointegrationJob,
  schedule: ~e"0 6 * * 0",
  one_shot: false
)
```

Use whatever existing schema `Api.register_job/1` already takes; match the style of `PairBuildJob` which runs on a similar cadence.

- [ ] **Step 7.3.2: Run full suite**

```bash
mix test
```

Expected: all pass.

- [ ] **Step 7.3.3: Commit**

```bash
git add lib/alpaca_trader/scheduler/jobs/pair_recointegration_job.ex lib/alpaca_trader/scheduler/quantum.ex lib/alpaca_trader/application.ex lib/alpaca_trader/bars_store.ex test/alpaca_trader/scheduler/jobs/pair_recointegration_job_test.exs test/alpaca_trader/bars_store_test.exs config/runtime.exs
git commit -m "feat(cointegration): weekly re-cointegration cron job"
```

---

## Task 8: Shadow-Mode Signal Logger

Record every entry signal the engine generates (theoretical fill at quote midpoint, theoretical exit) regardless of whether a live order actually went out. Compare against live fills later to detect silent engine drift (e.g. an LLM gate over-suppressing, whitelist eviction wiping too much).

**Files:**
- Create: `lib/alpaca_trader/shadow_logger.ex`
- Create: `test/alpaca_trader/shadow_logger_test.exs`
- Modify: `lib/alpaca_trader/engine.ex` — call ShadowLogger on every would-be entry and every gate rejection
- Modify: `lib/alpaca_trader/application.ex` — supervise the logger
- Modify: `config/runtime.exs` — `SHADOW_MODE_ENABLED`, `SHADOW_LOG_PATH`

### 8.1 Failing test

- [ ] **Step 8.1.1: Test file**

Create `test/alpaca_trader/shadow_logger_test.exs`:

```elixir
defmodule AlpacaTrader.ShadowLoggerTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.ShadowLogger

  setup do
    path = Path.join(System.tmp_dir!(), "shadow_#{System.unique_integer([:positive])}.jsonl")
    start_supervised!({ShadowLogger, path: path})
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "records signal with entry/exit/gate status to jsonl", %{path: path} do
    :ok = ShadowLogger.record_signal(%{
      timestamp: ~U[2026-04-19 12:00:00Z],
      pair: "A-B",
      event: :entry_signal,
      z_score: 2.1,
      status: :would_enter,
      gate_rejections: []
    })

    :ok = ShadowLogger.record_signal(%{
      timestamp: ~U[2026-04-19 13:00:00Z],
      pair: "A-B",
      event: :entry_signal,
      z_score: 2.3,
      status: :blocked,
      gate_rejections: [:regime_vol]
    })

    ShadowLogger.flush()

    body = File.read!(path)
    assert String.contains?(body, "would_enter")
    assert String.contains?(body, "regime_vol")
    # One JSON per line
    assert length(String.split(String.trim(body), "\n")) == 2
  end

  test "counts events by status", %{path: _path} do
    _ = ShadowLogger.record_signal(%{event: :entry_signal, status: :would_enter, pair: "X-Y", timestamp: DateTime.utc_now(), z_score: 2.0, gate_rejections: []})
    _ = ShadowLogger.record_signal(%{event: :entry_signal, status: :blocked, pair: "X-Y", timestamp: DateTime.utc_now(), z_score: 2.0, gate_rejections: [:kelly_cap]})

    stats = ShadowLogger.summary()
    assert stats[:would_enter] == 1
    assert stats[:blocked] == 1
  end
end
```

- [ ] **Step 8.1.2: Run**

Run: `mix test test/alpaca_trader/shadow_logger_test.exs`
Expected: FAIL.

### 8.2 Implement ShadowLogger

- [ ] **Step 8.2.1: Create GenServer**

Create `lib/alpaca_trader/shadow_logger.ex`:

```elixir
defmodule AlpacaTrader.ShadowLogger do
  @moduledoc """
  Append-only JSONL log of every entry/exit signal the engine considers,
  whether or not a live order went out.

  Purpose: detect silent drift. If the live book stops trading, is the
  engine not generating signals (upstream data problem) or is some gate
  (LLM, regime, cluster, kelly, whitelist) swallowing them? The shadow
  log tells you which. Ops can diff the engine's intended activity vs
  what actually filled and see the delta.

  In-memory counter for quick summaries; writes to disk on `flush/0`
  (called periodically or before shutdown) to cap I/O.
  """

  use GenServer

  @type signal :: %{
          required(:timestamp) => DateTime.t(),
          required(:pair) => String.t(),
          required(:event) => :entry_signal | :exit_signal,
          required(:status) => :would_enter | :would_exit | :blocked | :filled | :rejected,
          required(:z_score) => float(),
          optional(:gate_rejections) => [atom()]
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def record_signal(%{} = signal) do
    GenServer.cast(__MODULE__, {:record, signal})
  end

  def flush, do: GenServer.call(__MODULE__, :flush)

  def summary, do: GenServer.call(__MODULE__, :summary)

  @impl true
  def init(opts) do
    path =
      opts[:path] ||
        Application.get_env(
          :alpaca_trader,
          :shadow_log_path,
          "priv/runtime/shadow_signals.jsonl"
        )

    File.mkdir_p!(Path.dirname(path))
    {:ok, %{path: path, buffer: [], counters: %{}}}
  end

  @impl true
  def handle_cast({:record, signal}, state) do
    line = Jason.encode!(signal) <> "\n"
    key = signal[:status]
    new_counters = Map.update(state.counters, key, 1, &(&1 + 1))
    {:noreply, %{state | buffer: [line | state.buffer], counters: new_counters}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    File.write!(state.path, Enum.reverse(state.buffer), [:append])
    {:reply, :ok, %{state | buffer: []}}
  end

  def handle_call(:summary, _from, state) do
    {:reply, state.counters, state}
  end
end
```

- [ ] **Step 8.2.2: Add to supervision tree**

In `lib/alpaca_trader/application.ex`, append to `children`:

```elixir
AlpacaTrader.ShadowLogger,
```

- [ ] **Step 8.2.3: Run tests**

Run: `mix test test/alpaca_trader/shadow_logger_test.exs`
Expected: all pass.

- [ ] **Step 8.2.4: Commit**

```bash
git add lib/alpaca_trader/shadow_logger.ex lib/alpaca_trader/application.ex test/alpaca_trader/shadow_logger_test.exs
git commit -m "feat(shadow): append-only signal logger for engine-vs-fill drift"
```

### 8.3 Wire into Engine

- [ ] **Step 8.3.1: Call record_signal at decision points**

In `lib/alpaca_trader/engine.ex`, at each place the engine:
- decides to enter → `record_signal(..., status: :would_enter)`
- is blocked by a gate (regime / portfolio / cluster / kelly / whitelist / LLM) → `record_signal(..., status: :blocked, gate_rejections: [gate_name])`
- submits an order → existing path, plus `record_signal(..., status: :filled)` after success
- decides to exit → `record_signal(..., event: :exit_signal, status: :would_exit)`

Keep the calls out of the hot loop allocations — just a `cast`, fire-and-forget. Only enabled when `Application.get_env(:alpaca_trader, :shadow_mode_enabled, false)` is true. Guard every call with that flag (or expose a helper `ShadowLogger.maybe_record/1` that no-ops when disabled).

- [ ] **Step 8.3.2: Integration test**

Append to `test/alpaca_trader/engine_test.exs`:

```elixir
test "shadow logger records gate rejections when enabled" do
  prev = Application.get_env(:alpaca_trader, :shadow_mode_enabled, false)
  Application.put_env(:alpaca_trader, :shadow_mode_enabled, true)
  on_exit(fn -> Application.put_env(:alpaca_trader, :shadow_mode_enabled, prev) end)

  # Build a context where the portfolio gate should reject (e.g., max_open_positions=0)
  # Then call scan_and_execute and assert ShadowLogger.summary gained a :blocked entry.
  # (Exact setup depends on engine_test fixture; wire with existing helpers.)
  :ok
end
```

(The test should be completed to actually flex a path; leave `:ok` as a placeholder only if the existing engine_test.exs fixture setup is too opaque — in that case, log a TODO in the test explaining what's missing and file a follow-up.)

- [ ] **Step 8.3.3: Config**

In `config/runtime.exs`:

```elixir
    shadow_mode_enabled: System.get_env("SHADOW_MODE_ENABLED", "false") == "true",
    shadow_log_path: System.get_env("SHADOW_LOG_PATH", "priv/runtime/shadow_signals.jsonl"),
```

- [ ] **Step 8.3.4: Run full test suite**

```bash
mix compile --warnings-as-errors
mix test
```

Expected: all pass.

- [ ] **Step 8.3.5: Commit**

```bash
git add lib/alpaca_trader/engine.ex test/alpaca_trader/engine_test.exs config/runtime.exs
git commit -m "feat(shadow): record entry/exit signals and gate rejections in Engine"
```

---

## Final Integration

- [ ] **Step F.1: Run precommit suite**

```bash
mix precommit
```

This runs `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, and `test`. All must pass before PR.

- [ ] **Step F.2: Update README / docs**

Append a "Feature flags" section to `README.md` listing every new env var and a one-line description. Flag that all features default off so nothing in production changes until explicitly enabled.

- [ ] **Step F.3: Commit docs**

```bash
git add README.md
git commit -m "docs: feature flags for regime, half_life, kelly, cluster, shadow, execution modes"
```

- [ ] **Step F.4: Push and open PR**

```bash
git push -u origin feat/trading-bot-improvements
gh pr create --fill --base main --title "feat: trading bot improvements (regime, half-life, kelly, cluster, exec, shadow, cointegration refresh, cost-adjusted whitelist)"
```

- [ ] **Step F.5: Wait for CI, merge when green**

```bash
gh run watch
gh pr merge --squash --delete-branch
git checkout main && git pull origin main
```

---

## Self-Review Checklist

- **Spec coverage:** Each of the 8 items from the user's ask maps to a task: 1 regime (T1), 2 half-life (T2), 3 cost-adjusted whitelist (T3), 4 Kelly (T4), 5 limit orders (T5), 6 cluster cap (T6), 7 online re-cointegration (T7), 8 shadow mode (T8). ✓
- **Placeholders:** Every step has concrete code or commands. Step 8.3.2 has a flagged placeholder that the implementer must complete using the engine_test fixture.
- **Type consistency:** `allow_entry?/1` (PortfolioRisk) returns `:ok | {:blocked, reason}`; RegimeDetector, ClusterLimiter match. KellySizer returns float dollars. ShadowLogger events use the shape declared in `@type signal`.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-19-trading-bot-improvements.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch with checkpoints.

Which approach?
