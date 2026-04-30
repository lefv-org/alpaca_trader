# QuiverQuant Alt-Data Foundation — Design

**Status:** Draft for review
**Date:** 2026-04-30
**Scope:** Sub-project 1 of 3 in QuiverQuant integration

## Context

The bot already has an `AltData` subsystem (`lib/alpaca_trader/alt_data/`) with a
shared `Provider` behaviour, a normalized `Signal` struct, an ETS-backed
`SignalStore`, and a one-supervisor-per-provider topology. Existing providers
include FRED, Finnhub, Open-Meteo, OpenSky, NASA FIRMS, NWS. This sub-project
adds five QuiverQuant feeds as new alt-data providers — Congressional trades,
corporate insider filings, federal government contracts, lobbying disclosures,
and WallStreetBets sentiment.

Out of scope here (covered in follow-up sub-projects):

- Composite per-symbol score and gate integration with `PortfolioRisk` /
  `OrderRouter` (sub-project 2).
- Dedicated `QuiverFollow` strategy module (sub-project 3).

This sub-project ships only the data plumbing: every enabled feed writes a
list of `AltData.Signal` entries to `SignalStore` on its poll cadence. No
trading behaviour changes until later sub-projects consume those signals.

## Goals

1. Five feeds → `SignalStore` under provider keys `:quiver_congress`,
   `:quiver_insider`, `:quiver_govcontracts`, `:quiver_lobbying`, `:quiver_wsb`.
2. Each feed independently toggleable + tunable via env vars.
3. No regression: feeds default to disabled; supervisor only starts providers
   whose flag is true AND `QUIVERQUANT_API_KEY` is set.
4. Test coverage: client, parser, provider behaviour all unit-tested with
   fixtures; supervisor integration test boots full set against stubbed client.

## Non-Goals

- No score aggregation across feeds (sub-project 2).
- No new trading signals or strategy emission (sub-project 3).
- No historical persistence beyond what `SignalStore` provides
  (latest-replaces-previous per provider).
- No CLI / web dashboard for inspecting Quiver feeds.

## Architecture

```
lib/alpaca_trader/alt_data/
├── providers/
│   ├── quiver_congress.ex
│   ├── quiver_insider.ex
│   ├── quiver_govcontracts.ex
│   ├── quiver_lobbying.ex
│   └── quiver_wsb.ex
└── quiver/
    ├── client.ex   # HTTP wrapper, auth, retries
    └── parser.ex   # raw rows -> [AltData.Signal]
```

**Layer responsibilities**

- `Quiver.Client` — HTTP only. Knows base URL, key, retries, timeouts. Returns
  `{:ok, [map()]} | {:error, term()}`. No domain logic.
- `Quiver.Parser` — pure. Per-endpoint `parse_<feed>/2` functions transform
  raw rows + a `now :: DateTime.t()` into `[AltData.Signal.t()]`. Testable
  with JSON fixtures alone.
- `Providers.Quiver<Feed>` — five thin GenServers, each conforming to the
  existing `AltData.Provider` behaviour. Each schedules its own poll, calls
  `Client.get/2` then `Parser.parse_<feed>/2`, and writes to `SignalStore`.

**Wiring** — `AltData.Supervisor` adds five new children, each gated on its
`_enabled` env flag AND key presence. Existing FRED/Finnhub/etc. children
remain untouched. Pattern mirrors `alt_data_finnhub_enabled`.

## Signal Mapping

All providers produce `AltData.Signal` records. Mapping rules per feed:

### `:quiver_congress` — `/bulk/congresstrading`

- Group rows by `Ticker`, last `QUIVER_CONGRESS_LOOKBACK_D` (default 14) days.
- `direction`: net `Purchase` count > `Sale` count → `:bullish`; reverse →
  `:bearish`; mixed (within ±1) → `:neutral`.
- `strength`: `min(1.0, abs(net_count) / 5.0)`.
- `affected_symbols`: `[ticker]`.
- `signal_type`: `:congress_trade`.
- `expires_at`: `fetched_at + lookback_days`.
- `raw`: `%{filings: [...], net_count: integer, total_amount_range: [lo, hi]}`.

### `:quiver_insider` — `/beta/live/insiders`

- Group by ticker, last `QUIVER_INSIDER_LOOKBACK_D` (default 30) days. Only
  Form 4 transaction codes `P` (Purchase) and `S` (Sale).
- Detect cluster: 2+ distinct insiders same direction within a 14-day window.
- `direction`: by sign of net dollar value of P vs S.
- `strength`: `min(1.0, abs(net_dollars) / threshold)` where `threshold =
  500_000` for cluster, `1_000_000` for single. Cluster halves the threshold,
  raising strength faster.
- `signal_type`: `:insider_buy_cluster` or `:insider_sell_cluster` when
  cluster condition met; otherwise `:insider_trade`.
- `expires_at`: `fetched_at + lookback_days`.

### `:quiver_govcontracts` — `/beta/live/govcontractsall`

- Group by ticker, last `QUIVER_GOVCONTRACTS_LOOKBACK_D` (default 30) days.
- Skip rows with negative `Amount` (cancellations).
- `direction`: always `:bullish` for awards.
- `strength`: `min(1.0, total_amount / 100_000_000)` ($100M caps).
- `signal_type`: `:gov_contract_award`.
- `expires_at`: `fetched_at + lookback_days`.

### `:quiver_lobbying` — `/beta/live/lobbying`

- Group by ticker, latest disclosed quarter.
- `direction`: `:neutral` (lobbying signals attention, not direction).
- `strength`: `min(1.0, abs(spend_current - spend_prev_year) / max(1.0,
  spend_prev_year))`. Falls back to 0.0 when no prior-year disclosure exists.
- `signal_type`: `:lobbying_spike`.
- `expires_at`: `fetched_at + QUIVER_LOBBYING_LOOKBACK_D` (default 90 days).

### `:quiver_wsb` — `/beta/live/wallstreetbets`

- Per-symbol mention count + sentiment score from feed.
- `direction`: `:bullish` if `sentiment > 0.6` AND `mention_count >
  prev_day_mention_count`; `:bearish` if `sentiment < 0.4` AND `mention_count
  > prev_day_mention_count`; else `:neutral`. (Rising attention amplifies
  whichever sentiment direction is present.)
- `strength`: `min(1.0, mention_count / 500.0)`.
- `signal_type`: `:wsb_sentiment`.
- `expires_at`: `fetched_at + QUIVER_WSB_LOOKBACK_D` (default 1 day) — fast
  decay reflects sentiment volatility.

## HTTP Client

`AlpacaTrader.AltData.Quiver.Client`:

- Module-level constant `@base_url`, overridable via `:quiver_base_url`
  application env.
- API: `get(path :: String.t(), params :: map()) :: {:ok, [map()]} | {:error,
  term()}`.
- Auth: `Authorization: Bearer <key>` header from `:quiverquant_api_key`
  application env.
- HTTP lib: `Req` (already used by `Alpaca.Client`).
- Retries: 3 attempts on 429 / 5xx, exponential backoff 500ms / 1s / 2s.
- Timeout: 15s default, env-overridable via `QUIVER_TIMEOUT_MS`.
- Logging: `Logger.warning` on retry, `Logger.error` on final failure.

**Failure semantics**

- Provider catches `{:error, _}`, logs, and **does not** clear `SignalStore`.
  Stale signals continue to expire via TTL. Prevents flapping when API blips.
- 401 / 403 is logged once per provider startup; provider then becomes inert
  (subsequent ticks no-op until restart).

**Rate limits** — Quiver beta paid tier is ~300 req/min. Worst-case load is
five bulk requests per WSB poll cycle (450 s), nowhere near the cap. No
client-side throttle in v1; revisit only if observed 429s exceed retry
budget.

## Configuration

Env vars (defaults shown). `runtime.exs` adds these alongside the existing
`alt_data_*` block.

```
QUIVERQUANT_API_KEY=<required if any feed enabled>
QUIVER_BASE_URL=https://api.quiverquant.com/beta
QUIVER_TIMEOUT_MS=15000

QUIVER_CONGRESS_ENABLED=false
QUIVER_INSIDER_ENABLED=false
QUIVER_GOVCONTRACTS_ENABLED=false
QUIVER_LOBBYING_ENABLED=false
QUIVER_WSB_ENABLED=false

QUIVER_CONGRESS_POLL_S=1800        # 30 min
QUIVER_INSIDER_POLL_S=900          # 15 min
QUIVER_GOVCONTRACTS_POLL_S=10800   # 3 h
QUIVER_LOBBYING_POLL_S=43200       # 12 h
QUIVER_WSB_POLL_S=450              # 7.5 min

QUIVER_CONGRESS_LOOKBACK_D=14
QUIVER_INSIDER_LOOKBACK_D=30
QUIVER_GOVCONTRACTS_LOOKBACK_D=30
QUIVER_LOBBYING_LOOKBACK_D=90
QUIVER_WSB_LOOKBACK_D=1
```

Secret management follows global rules: `QUIVERQUANT_API_KEY` lives in `.env`,
synced via `lsh-framework`. `.env` is already gitignored.

## Testing

**Unit tests** (under `test/alpaca_trader/alt_data/`):

- `quiver/client_test.exs` — `Req.Test` stubs verify auth header presence,
  retry on 429 / 5xx, timeout handling, success path. Targets 100% branch
  coverage.
- `quiver/parser_test.exs` — fixture-driven. One test per endpoint asserting
  raw JSON → list of `AltData.Signal` with expected direction, strength,
  symbols, expiry, and `signal_type`.
- `providers/quiver_<feed>_test.exs` (×5) — stub `Quiver.Client`. Verify:
  1. Successful tick writes correct `provider` key + signal list to store.
  2. Error path does NOT clear `SignalStore`.
  3. Disabled mode (no key OR `_enabled=false`) is inert.

**Integration test** — `alt_data/quiver_supervisor_test.exs`: starts
`AltData.Supervisor` with all five Quiver toggles on, stubbed `Client`,
asserts five providers boot, each writes signals, and
`SignalStore.all_active/0` returns the combined set.

**Fixtures** — `test/support/fixtures/quiver/{congress,insider,govcontracts,
lobbying,wsb}.json`. Real-shape samples (sanitized, no PII), 5–10 rows each.
No captured API keys.

**No live API tests in CI.** Optional `mix test --only live_quiver` tag for
local smoke against real key.

## Risks & Mitigations

- **Quiver schema drift** — endpoints occasionally rename fields. Mitigation:
  parser tolerates missing keys, logs once when an expected field is absent;
  provider continues with whatever signals parser produced.
- **API tier mismatch** — user's key may not include all five endpoints.
  Mitigation: per-feed 401/403 handling makes that feed inert without
  affecting other feeds.
- **Polling pressure** — five providers polling concurrently could spike
  outbound HTTP load when cycles align (e.g. supervisor restart). Mitigation:
  each provider's `init/1` schedules its first tick via `Process.send_after`
  with a small randomized offset (0–`poll_s/4` seconds) so cycles desynchronize
  naturally.
- **STOCK Act delay** — Congressional filings have up to a 45-day reporting
  delay. Signals are inherently lagging; downstream consumers (sub-project 2)
  must weight accordingly. Documented; no plumbing work required here.

## Acceptance Criteria

1. With all five `_ENABLED=true` and a valid key, `mix test` passes including
   the new supervisor integration test.
2. With `_ENABLED=false` (default), zero new processes start; existing tests
   remain green; no behaviour change to engine or strategies.
3. With invalid key, providers log permission denied once and become inert;
   other alt-data providers remain healthy.
4. `SignalStore.status/0` reflects the five new providers when enabled, with
   non-zero signal counts after first poll.
5. No new compiler warnings, no Credo regressions.
