# Gain Accumulator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate all new trade entries so the engine only risks accumulated gains above original principal, protecting the principal permanently.

**Architecture:** A new `GainAccumulatorStore` GenServer snapshots equity on first call, persists it to a JSON file, and exposes `allow_entry?(equity)` which returns `true` only when `equity - principal >= ORDER_NOTIONAL`. The engine's three LLM-confirmed entry paths (`gate_and_enter`, `gate_and_flip`, `gate_and_rotate`) each call this gate before proceeding.

**Tech Stack:** Elixir, GenServer, Jason (already in deps), ExUnit

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `lib/alpaca_trader/gain_accumulator_store.ex` | Create | GenServer: snapshot, persist, gate logic |
| `test/alpaca_trader/gain_accumulator_store_test.exs` | Create | Unit tests for the store |
| `lib/alpaca_trader/application.ex` | Modify | Add store to supervision tree |
| `lib/alpaca_trader/engine.ex` | Modify | Add `gain_allows_entry?/1`, wire into 3 gate functions |
| `config/runtime.exs` | Modify | Add `GAIN_ACCUMULATOR_PATH` env var |

---

## Task 1: GainAccumulatorStore — tests + implementation

**Files:**
- Create: `lib/alpaca_trader/gain_accumulator_store.ex`
- Create: `test/alpaca_trader/gain_accumulator_store_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/alpaca_trader/gain_accumulator_store_test.exs`:

```elixir
defmodule AlpacaTrader.GainAccumulatorStoreTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.GainAccumulatorStore

  setup do
    tmp = System.tmp_dir!() <> "/gain_acc_test_#{:erlang.unique_integer([:positive])}.json"
    Application.put_env(:alpaca_trader, :gain_accumulator_path, tmp)
    Application.put_env(:alpaca_trader, :order_notional, "10")
    GainAccumulatorStore.reset()
    on_exit(fn -> File.rm(tmp) end)
    %{tmp: tmp}
  end

  test "first call snapshots principal and returns false", %{tmp: tmp} do
    refute GainAccumulatorStore.allow_entry?(100.0)
    assert GainAccumulatorStore.principal() == 100.0
    assert File.exists?(tmp)
    assert {:ok, %{"principal" => 100.0}} = Jason.decode(File.read!(tmp))
  end

  test "blocks entry when gain < order_notional" do
    GainAccumulatorStore.allow_entry?(100.0)   # snapshot
    refute GainAccumulatorStore.allow_entry?(105.0)  # gain=5, notional=10
  end

  test "allows entry when gain >= order_notional" do
    GainAccumulatorStore.allow_entry?(100.0)   # snapshot
    assert GainAccumulatorStore.allow_entry?(110.0)  # gain=10, notional=10
  end

  test "returns false when equity is nil" do
    GainAccumulatorStore.allow_entry?(100.0)   # snapshot
    refute GainAccumulatorStore.allow_entry?(nil)
  end

  test "trading_capital returns 0.0 before snapshot" do
    assert GainAccumulatorStore.trading_capital(120.0) == 0.0
  end

  test "trading_capital returns equity minus principal after snapshot" do
    GainAccumulatorStore.allow_entry?(100.0)
    assert GainAccumulatorStore.trading_capital(115.0) == 15.0
  end

  test "trading_capital floors at 0.0 when equity below principal" do
    GainAccumulatorStore.allow_entry?(100.0)
    assert GainAccumulatorStore.trading_capital(95.0) == 0.0
  end

  test "reset clears principal and deletes file", %{tmp: tmp} do
    GainAccumulatorStore.allow_entry?(100.0)
    assert File.exists?(tmp)
    GainAccumulatorStore.reset()
    assert GainAccumulatorStore.principal() == nil
    refute File.exists?(tmp)
  end

  test "reloads principal from file after restart", %{tmp: tmp} do
    GainAccumulatorStore.allow_entry?(99.0)
    assert File.exists?(tmp)

    :ok = GenServer.stop(GainAccumulatorStore)
    {:ok, _} = GainAccumulatorStore.start_link([])

    assert GainAccumulatorStore.principal() == 99.0
  end

  test "corrupt file starts with nil principal and logs warning", %{tmp: tmp} do
    File.write!(tmp, "not json {{{{")
    :ok = GenServer.stop(GainAccumulatorStore)
    {:ok, _} = GainAccumulatorStore.start_link([])
    assert GainAccumulatorStore.principal() == nil
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/alpaca_trader/gain_accumulator_store_test.exs 2>&1 | tail -10
```

Expected: compile error — `GainAccumulatorStore` does not exist.

- [ ] **Step 3: Implement GainAccumulatorStore**

Create `lib/alpaca_trader/gain_accumulator_store.ex`:

```elixir
defmodule AlpacaTrader.GainAccumulatorStore do
  @moduledoc """
  Tracks original principal from first-boot equity snapshot.
  Gates new trade entries: allows entry only when equity - principal >= ORDER_NOTIONAL.
  Principal persists to a JSON file across restarts.
  """

  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Returns true only when equity - principal >= order_notional.
  On first call (principal nil), snapshots equity, writes file, returns false.
  Returns false for nil equity.
  """
  def allow_entry?(nil), do: false

  def allow_entry?(equity) when is_number(equity) do
    GenServer.call(__MODULE__, {:allow_entry, equity})
  end

  @doc "Accumulated gain capital: max(0, equity - principal). Returns 0.0 before snapshot."
  def trading_capital(equity) when is_number(equity) do
    case principal() do
      nil -> 0.0
      p -> max(0.0, equity - p)
    end
  end

  @doc "Current principal. Nil if not yet snapshotted."
  def principal do
    GenServer.call(__MODULE__, :principal)
  end

  @doc "Clears state and deletes the JSON file. For testing and manual reset."
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # ── GenServer callbacks ─────────────────────────────────────

  @impl true
  def init(_) do
    state =
      case load_from_file() do
        {:ok, principal} ->
          Logger.info("[GainAccumulator] loaded principal=$#{Float.round(principal, 2)}")
          %{principal: principal}

        {:error, :not_found} ->
          %{principal: nil}

        {:error, reason} ->
          Logger.warning("[GainAccumulator] could not load file (#{reason}), starting fresh")
          %{principal: nil}
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:allow_entry, equity}, _from, %{principal: nil} = state) do
    new_state = %{state | principal: equity}
    persist(equity)
    Logger.info("[GainAccumulator] 📸 principal=$#{Float.round(equity, 2)} established")
    {:reply, false, new_state}
  end

  def handle_call({:allow_entry, equity}, _from, %{principal: principal} = state) do
    notional = parse_notional(Application.get_env(:alpaca_trader, :order_notional, "10"))
    gain = equity - principal

    if gain >= notional do
      Logger.info("[GainAccumulator] ✅ gain=$#{Float.round(gain, 2)} >= $#{notional} — entry allowed")
      {:reply, true, state}
    else
      Logger.debug("[GainAccumulator] 🔒 gain=$#{Float.round(gain, 2)} < $#{notional} — entry blocked")
      {:reply, false, state}
    end
  end

  def handle_call(:principal, _from, state) do
    {:reply, state.principal, state}
  end

  def handle_call(:reset, _from, state) do
    path = file_path()
    if File.exists?(path), do: File.rm(path)
    Logger.info("[GainAccumulator] reset — principal cleared")
    {:reply, :ok, %{state | principal: nil}}
  end

  # ── Persistence ─────────────────────────────────────────────

  defp file_path do
    Application.get_env(:alpaca_trader, :gain_accumulator_path, "priv/gain_accumulator.json")
  end

  defp load_from_file do
    path = file_path()

    case File.read(path) do
      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}

      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"principal" => p}} when is_number(p) -> {:ok, p * 1.0}
          _ -> {:error, :invalid_json}
        end
    end
  end

  defp persist(principal) do
    payload =
      Jason.encode!(%{
        principal: principal,
        snapshot_time: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    File.write(file_path(), payload)
  end

  defp parse_notional(n) when is_number(n), do: n * 1.0

  defp parse_notional(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 10.0
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/alpaca_trader/gain_accumulator_store_test.exs 2>&1 | tail -10
```

Expected: all tests pass. The `reloads principal from file after restart` test exercises the real restart path via `GenServer.stop` + `start_link`.

- [ ] **Step 5: Commit**

```bash
git add lib/alpaca_trader/gain_accumulator_store.ex test/alpaca_trader/gain_accumulator_store_test.exs
git commit -m "feat: add GainAccumulatorStore with JSON persistence and entry gate"
```

---

## Task 2: Add to supervision tree

**Files:**
- Modify: `lib/alpaca_trader/application.ex`

- [ ] **Step 1: Add GainAccumulatorStore to the children list**

In `lib/alpaca_trader/application.ex`, insert after `AlpacaTrader.PairPositionStore` and before `AlpacaTrader.LLM.OpinionGate`:

```elixir
children = [
  AlpacaTraderWeb.Telemetry,
  {DNSCluster, query: Application.get_env(:alpaca_trader, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: AlpacaTrader.PubSub},
  AlpacaTrader.AssetStore,
  AlpacaTrader.BarsStore,
  AlpacaTrader.PairPositionStore,
  AlpacaTrader.GainAccumulatorStore,        # ← add this line
  AlpacaTrader.LLM.OpinionGate,
  AlpacaTrader.MinuteBarCache,
  AlpacaTrader.Arbitrage.DiscoveryScanner,
  AlpacaTrader.Arbitrage.PairBuilder,
  AlpacaTrader.Polymarket.SignalGenerator,
  AlpacaTrader.Scheduler.Quantum,
  AlpacaTraderWeb.Endpoint
]
```

- [ ] **Step 2: Verify the full test suite still passes**

```bash
mix test 2>&1 | tail -10
```

Expected: all existing tests pass. The store starts cleanly alongside other children.

- [ ] **Step 3: Commit**

```bash
git add lib/alpaca_trader/application.ex
git commit -m "feat: add GainAccumulatorStore to supervision tree"
```

---

## Task 3: Wire gain gate into engine

**Files:**
- Modify: `lib/alpaca_trader/engine.ex`

The three LLM gate functions each call `execute_entry` or `execute_flip` after confirmation. Add a private helper `gain_allows_entry?/1` and gate each confirmed path. Exits always bypass the gate.

- [ ] **Step 1: Add `gain_allows_entry?/1` helper**

In `lib/alpaca_trader/engine.ex`, add this private helper in the `# ── HELPERS ──` section (near the bottom, above `do_scan`):

```elixir
defp gain_allows_entry?(ctx) do
  equity = parse_float(get_in(ctx.account, ["equity"]))
  AlpacaTrader.GainAccumulatorStore.allow_entry?(equity)
end
```

- [ ] **Step 2: Update `gate_and_enter/2`**

Replace the current `gate_and_enter/2` definition with:

```elixir
defp gate_and_enter(ctx, arb) do
  case AlpacaTrader.LLM.OpinionGate.evaluate(arb, ctx) do
    {:ok, %{decision: "suppress"}} ->
      Logger.info("[LLM Gate] SUPPRESSED #{arb.asset}: #{arb.reason}")
      []

    {:ok, %{conviction: c}} when c < 0.3 ->
      Logger.info("[LLM Gate] LOW CONVICTION #{Float.round(c, 2)} for #{arb.asset}")
      []

    {:ok, %{conviction: c, reasoning: r}} ->
      Logger.info("[LLM Gate] CONFIRMED #{arb.asset} conviction=#{Float.round(c, 2)}: #{r}")
      if gain_allows_entry?(ctx), do: execute_entry(ctx, arb), else: []

    _ ->
      if gain_allows_entry?(ctx), do: execute_entry(ctx, arb), else: []
  end
end
```

- [ ] **Step 3: Update `gate_and_flip/2`**

Replace the current `gate_and_flip/2` definition with:

```elixir
defp gate_and_flip(ctx, arb) do
  case AlpacaTrader.LLM.OpinionGate.evaluate(arb, ctx) do
    {:ok, %{decision: "suppress"}} ->
      Logger.info("[LLM Gate] SUPPRESSED flip #{arb.asset}")
      []

    {:ok, %{conviction: c}} when c < 0.3 ->
      # Low conviction on flip → just exit, don't reverse
      Logger.info("[LLM Gate] LOW CONVICTION flip #{arb.asset}, exiting instead")
      execute_exit(ctx, arb)

    {:ok, %{conviction: c, reasoning: r}} ->
      Logger.info("[LLM Gate] CONFIRMED flip #{arb.asset} conviction=#{Float.round(c, 2)}: #{r}")
      if gain_allows_entry?(ctx), do: execute_flip(ctx, arb), else: execute_exit(ctx, arb)

    _ ->
      if gain_allows_entry?(ctx), do: execute_flip(ctx, arb), else: execute_exit(ctx, arb)
  end
end
```

Note: when gain gate blocks a flip, we still execute the exit leg (close the position) — we just don't open the reversed entry.

- [ ] **Step 4: Update `gate_and_rotate/2`**

Replace the current `gate_and_rotate/2` definition with:

```elixir
defp gate_and_rotate(ctx, arb) do
  case AlpacaTrader.LLM.OpinionGate.evaluate(arb, ctx) do
    {:ok, %{decision: "suppress"}} ->
      Logger.info("[LLM Gate] SUPPRESSED rotation #{arb.asset}")
      []

    {:ok, %{conviction: c}} when c < 0.3 ->
      Logger.info("[LLM Gate] LOW CONVICTION #{Float.round(c, 2)} for rotation #{arb.asset}")
      []

    {:ok, %{conviction: c, reasoning: r}} ->
      Logger.info("[LLM Gate] CONFIRMED rotation #{arb.asset} conviction=#{Float.round(c, 2)}: #{r}")
      if gain_allows_entry?(ctx), do: execute_rotate(ctx, arb), else: []

    _ ->
      if gain_allows_entry?(ctx), do: execute_rotate(ctx, arb), else: []
  end
end
```

- [ ] **Step 5: Run full test suite**

```bash
mix test 2>&1 | tail -10
```

Expected: all tests pass. The engine tests don't exercise the gain gate directly (they stub the LLM) — that's fine, the gate is tested via `GainAccumulatorStoreTest`.

- [ ] **Step 6: Commit**

```bash
git add lib/alpaca_trader/engine.ex
git commit -m "feat: wire GainAccumulatorStore gate into engine entry paths"
```

---

## Task 4: Config — GAIN_ACCUMULATOR_PATH env var

**Files:**
- Modify: `config/runtime.exs`
- Modify: `.env.example`

- [ ] **Step 1: Add env var to runtime.exs**

In `config/runtime.exs`, inside the `if config_env() != :test do` block, add after the `order_notional` line:

```elixir
gain_accumulator_path: System.get_env("GAIN_ACCUMULATOR_PATH", "priv/gain_accumulator.json"),
```

So the block reads:

```elixir
config :alpaca_trader,
  alpaca_base_url: System.fetch_env!("ALPACA_BASE_URL"),
  alpaca_key_id: System.fetch_env!("ALPACA_KEY_ID"),
  alpaca_secret_key: System.fetch_env!("ALPACA_SECRET_KEY"),
  order_notional: System.get_env("ORDER_NOTIONAL", "10"),
  gain_accumulator_path: System.get_env("GAIN_ACCUMULATOR_PATH", "priv/gain_accumulator.json"),
  portfolio_reserve_pct: String.to_float(System.get_env("PORTFOLIO_RESERVE_PCT", "0.25")),
  # ... rest unchanged
```

- [ ] **Step 2: Add to .env.example**

Open `.env.example` and add after the `ORDER_NOTIONAL` line:

```
# Gain accumulator: path to principal snapshot file (must be writable)
# GAIN_ACCUMULATOR_PATH=priv/gain_accumulator.json
```

- [ ] **Step 3: Run full test suite one final time**

```bash
mix test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add config/runtime.exs .env.example
git commit -m "feat: add GAIN_ACCUMULATOR_PATH config for gain accumulator store"
```

---

## Self-Review

**Spec coverage:**
- ✅ First-boot snapshot → `handle_call({:allow_entry, equity}, ..., %{principal: nil})`
- ✅ Gate: `equity - principal >= ORDER_NOTIONAL` → allow; else block
- ✅ Halt new entries when gains eroded → `gate_and_enter/flip/rotate` all return `[]`
- ✅ `gate_and_flip` still exits on gain block — spec says exits bypass gate
- ✅ JSON flat file persistence with configurable path
- ✅ Corrupt file → warn + nil principal
- ✅ nil equity → `allow_entry?(nil)` returns false
- ✅ `reset/0` for tests and manual reset
- ✅ Supervised in application.ex before scan jobs

**Type consistency:**
- `allow_entry?/1` signature consistent across store module, engine helper, and tests
- `parse_notional/1` handles both string and number (matches `order_notional` env var which is a string)
- `principal/0` returns `float | nil` — `trading_capital/1` guards against nil correctly
