# Gain Accumulator — Design Spec
_2026-04-13_

## Problem

The account is capital-starved. A flat 25% portfolio reserve blocks most trades. The goal: protect original principal permanently, and only risk accumulated gains ("house money"). No gains → no new entries.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Principal establishment | First-boot snapshot | Automatic, no manual input; file survives restarts |
| Position sizing | Gate on fixed notional | Only trade when `equity - principal >= ORDER_NOTIONAL` |
| On gains eroded | Halt new entries | Let open positions exit normally; don't force-close |
| Persistence | JSON flat file | Human-readable, inspectable, resettable without Erlang knowledge |

## Architecture

```
GainAccumulatorStore (GenServer)
  ├── state: %{principal: float | nil}
  ├── on init: load priv/gain_accumulator.json → populate state
  │           file missing → principal: nil (snapshot deferred to first tick)
  └── public API:
        allow_entry?(equity) → boolean
        trading_capital(equity) → float
        principal() → float | nil
        reset() → :ok
```

## Data Flow

```
ArbitrageScanJob (every minute)
  └── Engine.scan_and_execute(ctx)
        └── for each hit:
              gate_and_enter | gate_and_flip | gate_and_rotate
                ├── LLM gate
                └── [if confirmed] GainAccumulatorStore.allow_entry?(equity)
                      ├── principal: nil  → snapshot, write JSON, return false
                      ├── equity - principal < ORDER_NOTIONAL → false
                      └── equity - principal >= ORDER_NOTIONAL → true
```

Exit path (`execute_exit`, close leg of `execute_flip`) bypasses the gate entirely. Only new entries are blocked.

## `allow_entry?/1` Logic

```elixir
def allow_entry?(equity) do
  # GenServer call → returns boolean
  # internally:
  #   if principal == nil: snapshot equity, persist, return false
  #   if equity - principal >= order_notional: true
  #   else: false
end
```

`order_notional` read from `Application.get_env(:alpaca_trader, :order_notional)` — DRY with engine.

## File Format

```json
{"principal": 98.76, "snapshot_time": "2026-04-13T16:18:00Z"}
```

Default path: `priv/gain_accumulator.json`
Configurable via: `GAIN_ACCUMULATOR_PATH` env var

## Error Handling

| Scenario | Behavior |
|---|---|
| File corrupt / unreadable | Log warning, start with `principal: nil`, re-snapshot next tick |
| Equity is nil (API garbage) | `allow_entry?` returns `false` (conservative) |
| `priv/` missing in prod | Set `GAIN_ACCUMULATOR_PATH` to a writable path |
| Manual reset | Delete file + call `GainAccumulatorStore.reset()` or restart app |

## Changes Required

| File | Change |
|---|---|
| `lib/alpaca_trader/gain_accumulator_store.ex` | New — GenServer + JSON persistence |
| `lib/alpaca_trader/application.ex` | Add to supervision tree (before scan jobs) |
| `lib/alpaca_trader/engine.ex` | Call `allow_entry?` in `gate_and_enter`, `gate_and_flip`, `gate_and_rotate` |
| `config/runtime.exs` | Add `GAIN_ACCUMULATOR_PATH` env var |
| `test/alpaca_trader/gain_accumulator_store_test.exs` | New — unit tests |

## Test Cases

- `principal: nil` on first call → snapshots equity, returns false
- `equity - principal < ORDER_NOTIONAL` → returns false
- `equity - principal >= ORDER_NOTIONAL` → returns true
- JSON persists and reloads correctly across GenServer restart
- `reset/0` clears state and deletes file
- Corrupt file → starts with nil, logs warning
