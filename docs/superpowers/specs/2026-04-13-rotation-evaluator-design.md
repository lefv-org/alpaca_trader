# Rotation Evaluator: Graph-Theoretic Portfolio Optimization

## Problem

Capital locked in stale positions can't pursue stronger signals. The engine had no mechanism to compare open positions against new opportunities — it only checked exit conditions for existing positions and entry conditions for new signals independently.

## Solution

**Iterative graph relaxation** modeled after shortest-path algorithms (Bellman-Ford).

- Portfolio state = node in an opportunity graph
- Each possible swap (close position X, enter signal Y) = directed edge
- Edge weight = `EV(Y) - remaining_EV(X) - txn_cost`
- Each scan cycle relaxes one edge (greedy single-swap)
- Recursive scanning spirals toward optimal allocation

Convergence guaranteed: bounded positions x positive hurdle per swap.

## Integration: Approach C (Inline in Entry Cascade)

When `check_entry_conditions` finds a Tier 2 or 3 signal, it routes through `maybe_rotate/2` before returning:

```
check_entry_conditions → tier hit → maybe_rotate(signal, open_positions)
  ├── {:rotate, victim}  → close victim, enter new signal
  ├── :enter_normally    → standard entry (no stale positions)
  └── :skip              → signal too weak to justify rotation
```

Tier 1 (Bellman-Ford cycles) bypasses rotation — cycle arbitrage is time-critical.

## Scoring

**Position remaining value:**
- `convergence` = how far z has reverted toward exit threshold (0.0 to 1.0)
- `time_used` = bars_held / max_hold_bars
- `remaining_ev` = (1 - convergence) x profit_target
- `stale?` = convergence > 0.6 AND time_used > 0.5

**Signal expected value:**
- `signal_ev` = profit_target x min(|z| / 2.0, 2.0)

**Rotation condition (all must hold):**
1. At least one open position is stale
2. New signal's EV exceeds victim's remaining EV + transaction costs
3. Net improvement > 0.3% minimum hurdle

## Transaction Cost Model

4 legs x 0.1% = 0.4% friction (2 exit + 2 entry for pairs)

## Guard Rails

- **Overlap rejection**: won't rotate a position that shares assets with the new signal (that's a flip, not a rotation)
- **LLM gate**: rotation signals pass through OpinionGate before execution
- **One swap per cycle**: greedy single-step prevents oscillation
- **Positive hurdle**: 0.3% minimum absorbs noise

## Files

- `lib/alpaca_trader/arbitrage/rotation_evaluator.ex` — scoring + evaluation
- `lib/alpaca_trader/engine.ex` — integration (`:rotate` action, `maybe_rotate/2`, `gate_and_rotate/2`, `execute_rotate/2`)
- `test/alpaca_trader/arbitrage/rotation_evaluator_test.exs` — 12 unit tests

## Supporting Changes

- `ArbitragePosition` struct: added `:replaces` field
- `config/test.exs`: added `skip_startup_sync: true`
- `application.ex`: skip sync jobs in test env
- `engine_test.exs`: fixed stale sell test (missing held position)
