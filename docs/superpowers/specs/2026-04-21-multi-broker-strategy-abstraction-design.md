# Multi-Broker + Strategy Abstraction

**Date:** 2026-04-21
**Status:** Design — approved, pending implementation plan
**Author:** Luis Fernández de la Vara

## Motivation

The current bot concentrates all responsibility inside `AlpacaTrader.Engine`: pair selection, LLM gating, portfolio risk, order construction, and Alpaca HTTP calls. Three pressures push us to split it up.

1. **Low trade frequency.** The existing pair-cointegration + long-only strategy only finds a handful of actionable signals per hour, and Alpaca's PDT rules plus long-only constraints trap the account after a few entries. Operating a single strategy on a single venue caps the opportunity surface.
2. **Single-venue lock-in.** Alpaca equities close overnight, enforce PDT on sub-$25k accounts, and cannot short crypto. A strategy that needs 24/7 execution or native shorting has nowhere to land.
3. **Monolithic engine.** The current engine mixes broker calls, strategy math, and policy (portfolio risk, gain gate, LLM gate) in one module. Adding a new strategy or broker requires touching every concern.

This spec introduces two thin behaviours — `Broker` and `Strategy` — and a narrow `OrderRouter` between them. The refactor lands in two parallel tracks (`A` and `B`) that share a small foundation PR.

## Goals

- Decouple strategy math from broker I/O. A strategy never imports broker HTTP code; a broker never knows what a pair trade is.
- Add Hyperliquid as a second broker (perps, 24/7, native shorting) behind the same abstraction as Alpaca.
- Add a new pluggable strategy (`FundingBasisArb`) alongside the ported pair-cointegration strategy, proving the abstraction carries ≥2 strategies.
- Centralize policy (portfolio risk, gain accumulator, LLM conviction, kill switch) in a single `OrderRouter`.
- Preserve the existing shadow-mode log, reconciler, and pair-position store — they become cross-cutting infrastructure, not engine internals.

## Non-goals

- No microservice split. Single BEAM node, single Phoenix app.
- No Rust/Go/Python sidecar. Fast-retail latency target (100ms–1s) is comfortably within Elixir + HTTP/WS.
- No sub-millisecond optimization. Not HFT.
- No on-chain wallet infrastructure beyond what Hyperliquid's SDK requires. One hot API wallet per environment, keys stored in LSH.
- No strategy-level position budgeting. All portfolio gates stay global for MVP.
- No multi-chain support. Hyperliquid only for now. dYdX etc. deferred.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Scheduler                                               │
└──────────────────────────┬───────────────────────────────┘
                           │ tick (1Hz equities, 100ms crypto)
                           ▼
┌──────────────────────────────────────────────────────────┐
│  StrategyRegistry                                        │
│  • iterates loaded strategies                            │
│  • collects signals                                      │
└──────┬────────────┬─────────────┬────────────────────────┘
       │            │             │
       ▼            ▼             ▼
 ┌─────────┐  ┌─────────┐  ┌──────────┐
 │ PairCo- │  │Funding  │  │ LeadLag  │  ◀─ each implements
 │integra- │  │BasisArb │  │ (later)  │     Strategy behaviour
 │tion     │  │         │  │          │
 └────┬────┘  └────┬────┘  └────┬─────┘
      │            │            │
      └──────┬─────┴────────────┘
             │ [%Signal{}]
             ▼
┌──────────────────────────────────────────────────────────┐
│  OrderRouter                                             │
│  • portfolio gates (sector cap, capital-at-risk)         │
│  • GainAccumulator gate                                  │
│  • LLM conviction gate                                   │
│  • venue selection + capabilities check                  │
│  • shadow-mode logging                                   │
│  • kill switch                                           │
└──────────────────────────┬───────────────────────────────┘
                           │ broker call
                           ▼
┌──────────────────────────────────────────────────────────┐
│  Broker behaviour   — submit / positions / account / WS  │
└──────┬──────────────────────┬──────────────────┬─────────┘
       ▼                      ▼                  ▼
  ┌─────────┐           ┌────────────┐      ┌──────┐
  │ Alpaca  │           │Hyperliquid │      │ Mock │
  └────┬────┘           └─────┬──────┘      └──────┘
       │                      │
       └─── ticks/fills ──────┴──▶ MarketDataBus (GenStage)
                                    ▲
                                    │ reads
                              strategies + OrderRouter
```

**Flow**

1. `Scheduler` ticks `StrategyRegistry` on per-strategy cadence.
2. `StrategyRegistry` invokes each loaded `Strategy`'s `scan/2` and `exits/2`, collecting `%Signal{}` lists.
3. `OrderRouter` receives signals, applies every gate in sequence, drops or routes.
4. Router calls `Broker.submit_order/2` on the venue declared by each leg.
5. Broker adapters normalize venue-native responses into `%Order{}`, `%Position{}`, `%Fill{}`.
6. `MarketDataBus` publishes ticks and fills to a GenStage pipeline; strategies and Router subscribe.

## Behaviours

### `AlpacaTrader.Broker`

```elixir
@callback submit_order(order :: Order.t(), opts :: keyword) ::
            {:ok, Order.t()} | {:error, term}
@callback cancel_order(broker_order_id :: String.t()) :: :ok | {:error, term}
@callback positions() :: {:ok, [Position.t()]} | {:error, term}
@callback account() :: {:ok, Account.t()} | {:error, term}
@callback bars(symbol :: String.t(), opts :: keyword) :: {:ok, [Bar.t()]} | {:error, term}
@callback stream_ticks(symbols :: [String.t()], subscriber :: pid) ::
            {:ok, reference} | {:error, term}
@callback funding_rate(symbol :: String.t()) :: {:ok, Decimal.t()} | {:error, term}
@callback capabilities() :: capabilities_map()
```

`capabilities/0` returns a static map describing the venue:

```elixir
%{
  shorting: true,
  perps: true,
  fractional: true,
  min_notional: Decimal.new("1.00"),
  fee_bps: 5,
  hours: :h24
}
```

Broker adapters own:
- HTTP client (Req, with retry + circuit breaker)
- WebSocket ticker subscriptions
- Auth (Alpaca header pair; Hyperliquid EIP-712 signing)
- Symbol normalization
- Response decoding into normalized structs

Broker adapters do **not** own: gating, strategy logic, position reconciliation with strategy state, or portfolio risk.

### `AlpacaTrader.Strategy`

```elixir
@callback id() :: atom
@callback required_feeds() :: [FeedSpec.t()]
@callback init(config :: map) :: {:ok, state} | {:error, term}
@callback scan(state, ctx :: MarketContext.t()) :: {:ok, [Signal.t()], state}
@callback on_fill(state, fill :: Fill.t()) :: {:ok, state}
@callback exits(state, ctx :: MarketContext.t()) :: {:ok, [Signal.t()], state}
```

Each strategy runs as a supervised GenServer. The supervisor is `one_for_one` — a crashed strategy does not affect its siblings. Strategy state holds open positions and any per-strategy accumulators (rolling z-scores, beta estimates, funding history).

Strategies do **not** call brokers directly. They emit Signals and read `MarketContext` / `MarketDataBus`.

### `%Signal{}`

```elixir
%Signal{
  id: uuid,
  strategy: :funding_basis_arb,
  atomic: true,
  legs: [
    %Leg{venue: :hyperliquid, symbol: "BTC-PERP", side: :short,
         size_mode: :notional, size: 50.0, type: :market},
    %Leg{venue: :alpaca, symbol: "IBIT", side: :long,
         size_mode: :notional, size: 50.0, type: :market}
  ],
  conviction: 0.8,
  reason: "funding +32bps, basis +0.4%",
  ttl_ms: 2000,
  meta: %{z_score: 2.1, funding_rate: 0.00032}
}
```

Fields:
- `atomic: true` — router must submit both legs or reject the signal. `false` permits partial routing (e.g. long-only drops the short leg).
- `size_mode` — one of `:notional | :qty | :pct_equity`.
- `ttl_ms` — router drops signals older than this before submission.
- `conviction` — strategy-internal score, combined with external LLM conviction by the Router.

## Strategies

### Ported: `PairCointegration`

Wraps the existing engine's pair-selection, cointegration, z-score, regime, and exit logic behind the new behaviour. Implementation steps:

1. Move `Engine.scan_arbitrage_opportunities/1` into `Strategies.PairCointegration.scan/2`, replacing direct Alpaca calls with `MarketContext` reads.
2. Convert the current `{:execute, %ArbitragePosition{}}` output into `%Signal{}` with two legs (for tier 2/3) or one leg (tier 1).
3. Move gate code (`GainAccumulator`, `PortfolioRisk`, LLM confirm) out of `Engine` into `OrderRouter`.
4. `long_only_mode` becomes a router policy, not strategy logic: Router inspects `Broker.capabilities()` and drops the short leg if `atomic: false` and venue cannot short. Current tier 2/3 build-entry branches collapse into unconditional pair emission.

### New: `FundingBasisArb`

**Thesis.** Hyperliquid perps pay funding hourly. When funding diverges from the carry cost of a correlated Alpaca proxy, a delta-neutral position harvests the spread until funding flips or basis converges.

**Asset proxy map** (config):

```elixir
config :alpaca_trader, :asset_proxies, %{
  "BTC-PERP"  => %{alpaca: "IBIT", beta: 1.0, quality: :high},
  "ETH-PERP"  => %{alpaca: "ETHA", beta: 1.0, quality: :high},
  "SOL-PERP"  => %{alpaca: "SOLZ", beta: 1.0, quality: :medium},
  "HYPE-PERP" => %{alpaca: nil,    beta: nil, quality: :none}
}
```

Beta defaults to 1.0 for spot-ETF proxies. Rolling-OLS beta estimation is deferred.

**Scan loop** (runs hourly on funding update + every 5min on basis):

1. Fetch funding rate `r` for each perp in the proxy map.
2. Fetch basis `b = (perp_mid - spot_proxy_mid) / spot_proxy_mid`.
3. Compute score `s = r - fee_bps/10000 - basis_adjustment`.
4. If `|s| > 10 bps`, emit a two-leg Signal:
   - Positive score: short perp on HL, long proxy on Alpaca.
   - Negative score: long perp on HL, short proxy on Alpaca (only if shorting enabled).
5. Size: `min(max_notional_per_leg, broker.buying_power × 0.1)`.

**Exits:**
- Funding flips sign.
- `|basis| < 5 bps`.
- 24 hours since entry.
- Portfolio-wide stop at -1% session P&L.

**Known risks:**
- Proxy tracking error. IBIT is NAV-based, BTC-PERP is a funded future — spread can persist.
- Alpaca PDT traps the equity leg under $25k equity. Mitigation: prefer Alpaca's own crypto leg (BTC/USD spot) where available; it bypasses PDT.
- Hyperliquid perp liquidation risk. Use isolated margin at 2–3× max.

### Deferred: `LeadLag`

Crypto-to-equity lead-lag (BTC ticks first, MSTR/COIN lag). Design in a follow-up spec once MVP lands.

## Policy: `OrderRouter`

Centralizes every decision between a Signal being emitted and an order hitting a broker:

1. **TTL check.** Drop if `age > ttl_ms`.
2. **Kill switch.** Drop if `TRADING_ENABLED=false`.
3. **Capabilities.** For each leg, check `Broker.capabilities()`. If incompatible, either drop the leg (when `atomic: false`) or reject the Signal.
4. **Portfolio gates.** Existing `PortfolioRisk` (sector cap, max open, capital-at-risk) — now global across strategies.
5. **GainAccumulator gate.** Existing gate, unchanged.
6. **LLM conviction gate.** Existing gate, applied only to equity legs by default. Configurable per-strategy.
7. **Atomic submission.** Submit all legs concurrently via `Task.async_stream`. On partial fill, issue reversing market order on the filled leg and log `atomic-break rollback`.
8. **Shadow log.** Every decision (submit, drop, reject) appended to `priv/runtime/shadow_signals.jsonl` with the reason.

## Parallel tracks

### Foundation PR (blocks A and B)

- Define `Broker` and `Strategy` behaviour modules.
- Define `Order`, `Position`, `Account`, `Bar`, `Tick`, `Fill`, `Signal`, `Leg`, `FeedSpec` structs.
- No implementations, no refactor. ~200 LOC, merged first.

### Track A — `refactor/broker-abstraction`

1. Extract all Alpaca HTTP/WS code from `engine.ex` into `Brokers.Alpaca`.
2. `Brokers.Alpaca` implements the `Broker` behaviour.
3. Add `Brokers.Mock` for tests.
4. Add `Brokers.Hyperliquid` skeleton — `submit_order`, `positions`, `account`, `funding_rate` against HL testnet. `stream_ticks` may stub in phase 1.
5. Existing test suite passes with strategy still running through `Brokers.Alpaca`.

### Track B — `refactor/strategy-abstraction` (rebases on A)

1. Build `StrategyRegistry` GenServer + `one_for_one` supervisor.
2. Build `OrderRouter` — lift gates out of engine.
3. Port `PairCointegration` into the behaviour.
4. Build `FundingBasisArb` against `Brokers.Mock` first.
5. Integration test: Registry + Router + Mock broker + FundingBasisArb produces expected signal stream from fixture data.
6. Swap Mock for `Brokers.Hyperliquid` in a separate `feat/funding-basis-live` branch tagged `:hyperliquid_testnet`. Nightly CI only.

**Merge order:** Foundation → A → B. Both within ~1 week.

## Error handling

- **Circuit breaker per broker.** Threshold: 5 consecutive 5xx or timeout within 30s. Open state rejects new signals to that venue, logs warning, emits metric. Half-open after 30s.
- **Retry budget.** 3 retries with exponential backoff, capped by Signal `ttl_ms`.
- **Atomic-break rollback.** If N legs submitted and only M < N fill, reverse each filled leg with an opposite-side market order. Log at warning level. If atomic-break rate exceeds 1% of signals over a rolling hour, auto-disable the emitting strategy.
- **Kill switch.** `TRADING_ENABLED` env flag. Checked at Router entry. Strategies continue scanning and logging.
- **Wallet custody (Hyperliquid).** Separate funding wallet and API-trading wallet. Private key for the API wallet in LSH-managed env var `HL_API_WALLET_KEY`. Never logged. One wallet per environment.

## Testing

- **Unit.** Strategy implementations tested with `Brokers.Mock`. Broker implementations tested with fixture HTTP via `Req.Test`. Each OrderRouter gate tested in isolation.
- **Integration — testnet.** `Brokers.Hyperliquid` runs against HL testnet. Full signal → submit → fill → position-update loop. Tagged `:hyperliquid_testnet`, excluded from default `mix test`, run nightly in CI.
- **Replay harness.** Existing `shadow_signals.jsonl` replayed through Router + Mock broker to verify refactor does not change decision output. Runs during PR review.
- **Property tests.** Signal → Order conversion preserves notional, side, venue (StreamData + Decimal roundtrip).

## Observability

- Extend `shadow_signals.jsonl` schema with `venue`, `strategy`, and per-leg fields.
- Add Prometheus-style metrics (via `:telemetry`): signals emitted, signals dropped by gate, broker latency histogram, atomic-break rate, funding harvest P&L.
- LiveView dashboard (new route `/admin/strategies`) shows per-strategy signal rate, fill rate, and session P&L.

## Open questions

- **Strategy-level position budgets.** Today `PortfolioRisk` aggregates across all strategies. Whether strategies eventually get independent budgets is deferred until MVP data informs the call.
- **LLM gate applicability to perps.** Current gate is ticker-validation. Hyperliquid perp symbols are a different universe — gate is disabled for HL legs in MVP, revisited after live runs.
- **Funding-rate data cadence.** Hourly pull sufficient initially. Switch to per-minute only if FundingBasisArb shows signal decay.
- **Beta estimation.** Fixed 1.0 for spot-ETF proxies in MVP. Rolling OLS or Kalman filter deferred.
- **LeadLag strategy design.** Separate brainstorm after MVP lands.

## Rollout

1. Foundation PR merged.
2. Track A and Track B merged behind `TRADING_ENABLED=false` on main branch.
3. Replay harness run against last 30 days of production shadow logs; zero decision drift is the gate.
4. `TRADING_ENABLED=true` on Alpaca-only (existing behaviour).
5. Hyperliquid testnet wiring validated via nightly CI for 1 week.
6. `FundingBasisArb` enabled on Hyperliquid testnet with live strategy logic, paper/sim only.
7. Promote to live Hyperliquid with $100 test capital.
8. Scale gradually: capital doubles every week as long as realized P&L tracks backtest within 50%.

## Success criteria

- Trade frequency per 24h increases ≥10× versus current long-only pair bot.
- Zero decision drift on replayed shadow logs.
- Atomic-break rate <1% across first 100 signals.
- FundingBasisArb live on HL testnet ≤2 weeks after Foundation PR.
