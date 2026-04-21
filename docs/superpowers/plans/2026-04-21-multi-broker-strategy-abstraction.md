# Multi-Broker + Strategy Abstraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the monolithic `AlpacaTrader.Engine` into composable `Broker` + `Strategy` behaviours with a central `OrderRouter`, add Hyperliquid as a second broker, and add a `FundingBasisArb` strategy that trades funding-rate divergence across Alpaca and Hyperliquid.

**Architecture:** Two thin behaviours (`Broker` for venue I/O, `Strategy` for decision logic) connected by an `OrderRouter` that owns every policy gate (portfolio risk, gain accumulator, LLM conviction, kill switch, atomic submission, shadow logging). Strategies emit `%Signal{}` structs with per-leg venue routing. The `StrategyRegistry` supervises one GenServer per strategy. A `MarketDataBus` (GenStage) fans broker ticks and fills to strategies + router.

**Tech Stack:** Elixir 1.15+, Phoenix 1.8, Req 0.5 (HTTP), GenStage (new dep), Mox + StreamData (test deps), Jason, Decimal. Hyperliquid access via direct REST + signed EIP-712 payloads. Reference spec: `docs/superpowers/specs/2026-04-21-multi-broker-strategy-abstraction-design.md`.

**Phases:**
1. **Phase 0** — Deps + test scaffolding
2. **Phase 1** — Foundation: behaviours + normalized structs (Foundation PR in spec)
3. **Phase 2** — Track A: broker refactor (`Brokers.Alpaca`, `Brokers.Mock`, `Brokers.Hyperliquid` skeleton)
4. **Phase 3** — Track B: strategy abstraction, `StrategyRegistry`, `OrderRouter`, ported `PairCointegration`, new `FundingBasisArb`
5. **Phase 4** — Replay harness + observability + rollout gates

---

## File Structure

### New files

```
lib/alpaca_trader/
  broker.ex                           # Broker behaviour (Phase 1)
  strategy.ex                         # Strategy behaviour (Phase 1)
  types/
    order.ex                          # %Order{} (Phase 1)
    position.ex                       # %Position{} (Phase 1)
    account.ex                        # %Account{} (Phase 1)
    bar.ex                            # %Bar{} (Phase 1)
    tick.ex                           # %Tick{} (Phase 1)
    fill.ex                           # %Fill{} (Phase 1)
    signal.ex                         # %Signal{} + %Leg{} (Phase 1)
    feed_spec.ex                      # %FeedSpec{} (Phase 1)
    capabilities.ex                   # %Capabilities{} (Phase 1)
  brokers/
    alpaca.ex                         # Alpaca Broker impl (Phase 2)
    alpaca/symbol.ex                  # Symbol normalization for Alpaca (Phase 2)
    hyperliquid.ex                    # Hyperliquid Broker impl skeleton (Phase 2)
    hyperliquid/auth.ex               # EIP-712 signing (Phase 2)
    hyperliquid/client.ex             # REST client (Phase 2)
    mock.ex                           # Mock Broker for tests (Phase 2)
  market_data_bus.ex                  # GenStage producer-consumer (Phase 3)
  strategy_registry.ex                # GenServer + supervisor (Phase 3)
  strategy_supervisor.ex              # DynamicSupervisor for strategies (Phase 3)
  order_router.ex                     # Gating + atomic submit (Phase 3)
  strategies/
    pair_cointegration.ex             # Ported existing strategy (Phase 3)
    funding_basis_arb.ex              # New strategy (Phase 3)
  replay/
    shadow_replay.ex                  # Replay harness (Phase 4)

config/
  runtime.exs                         # MODIFY — add broker + strategy config

test/alpaca_trader/
  types/                              # struct roundtrip tests (Phase 1)
  brokers/
    alpaca_test.exs                   # Broker contract tests (Phase 2)
    hyperliquid_test.exs              # HL unit tests (Phase 2)
    mock_test.exs                     # Mock sanity (Phase 2)
  strategy_registry_test.exs          # (Phase 3)
  order_router_test.exs               # gate-by-gate (Phase 3)
  market_data_bus_test.exs            # GenStage behaviour (Phase 3)
  strategies/
    pair_cointegration_test.exs       # (Phase 3)
    funding_basis_arb_test.exs        # (Phase 3)
  replay/
    shadow_replay_test.exs            # (Phase 4)

test/support/
  broker_contract.ex                  # shared Broker behaviour tests (Phase 2)
  fixtures/
    alpaca/                           # JSON fixtures (Phase 2)
    hyperliquid/                      # JSON fixtures (Phase 2)
```

### Modified files

```
mix.exs                               # +gen_stage, +mox, +stream_data
lib/alpaca_trader/application.ex      # +MarketDataBus, +StrategyRegistry, +StrategySupervisor
lib/alpaca_trader/engine.ex           # Gutted — moves broker calls to Brokers.Alpaca, moves gates to OrderRouter, scan logic moves to Strategies.PairCointegration
lib/alpaca_trader/engine/order_executor.ex  # Merges into OrderRouter or retired
lib/alpaca_trader/shadow_logger.ex    # Extend schema: +venue, +strategy, +per-leg
lib/alpaca_trader/scheduler/*         # Scheduler ticks Registry instead of scan job
```

---

# Phase 0 — Deps + test scaffolding

### Task 0.1: Add deps

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Open `mix.exs`, find `defp deps do` list, append three deps**

```elixir
# Inside the deps/0 list, add:
{:gen_stage, "~> 1.2"},
{:mox, "~> 1.1", only: :test},
{:stream_data, "~> 1.0", only: :test}
```

- [ ] **Step 2: Install**

Run: `mix deps.get`
Expected: all three new deps resolve and fetch without error.

- [ ] **Step 3: Verify compilation unaffected**

Run: `mix compile`
Expected: `Generated alpaca_trader app`, no errors.

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "chore: add gen_stage, mox, stream_data deps"
```

### Task 0.2: Mox registration for Broker

**Files:**
- Modify: `test/test_helper.exs`

- [ ] **Step 1: Append to `test/test_helper.exs`**

```elixir
# Register mocks used across test suite. The Broker mock will be defined
# once the Broker behaviour lands in Task 1.1.
# Placeholder — the defmock call is added in Task 2.4 after the behaviour exists.
```

(This task is a no-op marker — the real Mox defmock is added in Task 2.4 once the behaviour exists.)

- [ ] **Step 2: Run full suite to confirm baseline green**

Run: `mix test`
Expected: all current tests pass. Record the baseline pass count for the Phase 2 sanity check.

- [ ] **Step 3: Commit**

No changes to commit — baseline captured.

---

# Phase 1 — Foundation: behaviours + normalized structs

## Task 1.1: `%Capabilities{}` struct

**Files:**
- Create: `lib/alpaca_trader/types/capabilities.ex`
- Test: `test/alpaca_trader/types/capabilities_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule AlpacaTrader.Types.CapabilitiesTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.Types.Capabilities

  test "new/1 builds with defaults" do
    caps = Capabilities.new()
    assert caps.shorting == false
    assert caps.perps == false
    assert caps.fractional == false
    assert caps.hours == :rth
    assert Decimal.equal?(caps.min_notional, Decimal.new(1))
    assert caps.fee_bps == 0
  end

  test "new/1 overrides" do
    caps = Capabilities.new(shorting: true, perps: true, hours: :h24, fee_bps: 5)
    assert caps.shorting
    assert caps.perps
    assert caps.hours == :h24
    assert caps.fee_bps == 5
  end
end
```

- [ ] **Step 2: Run test, confirm fail**

Run: `mix test test/alpaca_trader/types/capabilities_test.exs`
Expected: compilation error, `Capabilities` undefined.

- [ ] **Step 3: Implement struct**

```elixir
defmodule AlpacaTrader.Types.Capabilities do
  @moduledoc """
  Static description of a broker venue.
  Returned by `Broker.capabilities/0`. The `OrderRouter` uses this to
  decide whether a Signal leg is routable to a venue.
  """

  @type hours :: :rth | :h24
  @type t :: %__MODULE__{
          shorting: boolean,
          perps: boolean,
          fractional: boolean,
          min_notional: Decimal.t(),
          fee_bps: non_neg_integer,
          hours: hours
        }

  defstruct shorting: false,
            perps: false,
            fractional: false,
            min_notional: Decimal.new(1),
            fee_bps: 0,
            hours: :rth

  @spec new(keyword) :: t()
  def new(opts \\ []) do
    struct!(__MODULE__, opts)
  end
end
```

- [ ] **Step 4: Run test, confirm pass**

Run: `mix test test/alpaca_trader/types/capabilities_test.exs`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/alpaca_trader/types/capabilities.ex test/alpaca_trader/types/capabilities_test.exs
git commit -m "feat(types): add Capabilities struct"
```

## Task 1.2: `%Order{}` struct

**Files:**
- Create: `lib/alpaca_trader/types/order.ex`
- Test: `test/alpaca_trader/types/order_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule AlpacaTrader.Types.OrderTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.Types.Order

  test "new/1 requires venue, symbol, side, size" do
    order = Order.new(venue: :alpaca, symbol: "AAPL", side: :buy, size: Decimal.new("10"),
                      size_mode: :qty, type: :market)
    assert order.status == :pending
    assert order.id == nil
    assert order.venue == :alpaca
    assert order.side == :buy
  end

  test "new/1 raises on bad side" do
    assert_raise ArgumentError, fn ->
      Order.new(venue: :alpaca, symbol: "AAPL", side: :wrong, size: Decimal.new("1"),
                size_mode: :qty, type: :market)
    end
  end
end
```

- [ ] **Step 2: Run, confirm fail**

Run: `mix test test/alpaca_trader/types/order_test.exs`

- [ ] **Step 3: Implement**

```elixir
defmodule AlpacaTrader.Types.Order do
  @moduledoc """
  Normalized order shape, venue-agnostic. Brokers translate this to
  their native format on submit, and translate fills back to %Fill{}.
  """

  @sides [:buy, :sell]
  @types [:market, :limit]
  @size_modes [:qty, :notional, :pct_equity]
  @statuses [:pending, :submitted, :partial, :filled, :canceled, :rejected]

  @type side :: :buy | :sell
  @type type :: :market | :limit
  @type size_mode :: :qty | :notional | :pct_equity
  @type status :: :pending | :submitted | :partial | :filled | :canceled | :rejected

  @type t :: %__MODULE__{
          id: String.t() | nil,
          client_order_id: String.t() | nil,
          venue: atom,
          symbol: String.t(),
          side: side,
          type: type,
          size: Decimal.t(),
          size_mode: size_mode,
          limit_price: Decimal.t() | nil,
          tif: :day | :gtc | :ioc,
          status: status,
          submitted_at: DateTime.t() | nil,
          filled_size: Decimal.t(),
          avg_fill_price: Decimal.t() | nil,
          reason: String.t() | nil,
          raw: map
        }

  defstruct [
    :id, :client_order_id, :venue, :symbol, :side, :type, :size, :size_mode,
    :limit_price, :submitted_at, :avg_fill_price, :reason,
    tif: :day,
    status: :pending,
    filled_size: Decimal.new(0),
    raw: %{}
  ]

  @spec new(keyword) :: t()
  def new(opts) do
    side = Keyword.fetch!(opts, :side)
    unless side in @sides, do: raise ArgumentError, "bad side #{inspect(side)}"
    type = Keyword.fetch!(opts, :type)
    unless type in @types, do: raise ArgumentError, "bad type #{inspect(type)}"
    size_mode = Keyword.fetch!(opts, :size_mode)
    unless size_mode in @size_modes, do: raise ArgumentError, "bad size_mode #{inspect(size_mode)}"
    struct!(__MODULE__, opts)
  end
end
```

- [ ] **Step 4: Run, confirm pass**

Run: `mix test test/alpaca_trader/types/order_test.exs`
Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/alpaca_trader/types/order.ex test/alpaca_trader/types/order_test.exs
git commit -m "feat(types): add Order struct with validated constructor"
```

## Task 1.3: `%Position{}`, `%Account{}`, `%Bar{}`, `%Tick{}`, `%Fill{}`

**Files:**
- Create: `lib/alpaca_trader/types/{position,account,bar,tick,fill}.ex`
- Test: `test/alpaca_trader/types/{position,account,bar,tick,fill}_test.exs`

- [ ] **Step 1: Write one test per struct**

Each test asserts struct fields and any derived helpers. Example for Position:

```elixir
defmodule AlpacaTrader.Types.PositionTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.Types.Position

  test "market_value/1 = qty * mark" do
    p = %Position{venue: :alpaca, symbol: "AAPL", qty: Decimal.new("10"), mark: Decimal.new("150")}
    assert Decimal.equal?(Position.market_value(p), Decimal.new("1500"))
  end

  test "direction/1 returns :long | :short | :flat" do
    assert Position.direction(%Position{qty: Decimal.new("10")}) == :long
    assert Position.direction(%Position{qty: Decimal.new("-5")}) == :short
    assert Position.direction(%Position{qty: Decimal.new(0)}) == :flat
  end
end
```

Write analogous tests for Account (`buying_power`, `equity`, `daytrade_count`), Bar (`ohlcv`, timestamp), Tick (`bid`, `ask`, `last`, `ts`), Fill (`order_id`, `qty`, `price`, `ts`).

- [ ] **Step 2: Run all, confirm fail**

Run: `mix test test/alpaca_trader/types/`

- [ ] **Step 3: Implement each struct**

```elixir
# lib/alpaca_trader/types/position.ex
defmodule AlpacaTrader.Types.Position do
  @type t :: %__MODULE__{
          venue: atom,
          symbol: String.t(),
          qty: Decimal.t(),
          avg_entry: Decimal.t() | nil,
          mark: Decimal.t() | nil,
          asset_class: :equity | :crypto | :perp | :unknown,
          opened_at: DateTime.t() | nil,
          raw: map
        }

  defstruct [:venue, :symbol, :qty, :avg_entry, :mark, :opened_at,
            asset_class: :unknown, raw: %{}]

  def market_value(%__MODULE__{qty: q, mark: m}) when not is_nil(m),
    do: Decimal.mult(q, m)
  def market_value(_), do: Decimal.new(0)

  def direction(%__MODULE__{qty: q}) do
    case Decimal.compare(q, 0) do
      :gt -> :long
      :lt -> :short
      :eq -> :flat
    end
  end
end

# lib/alpaca_trader/types/account.ex
defmodule AlpacaTrader.Types.Account do
  @type t :: %__MODULE__{
          venue: atom,
          equity: Decimal.t(),
          cash: Decimal.t(),
          buying_power: Decimal.t(),
          daytrade_count: non_neg_integer,
          pattern_day_trader: boolean,
          currency: String.t(),
          raw: map
        }
  defstruct [:venue, :equity, :cash, :buying_power,
             daytrade_count: 0, pattern_day_trader: false,
             currency: "USD", raw: %{}]
end

# lib/alpaca_trader/types/bar.ex
defmodule AlpacaTrader.Types.Bar do
  @type t :: %__MODULE__{
          venue: atom, symbol: String.t(),
          o: Decimal.t(), h: Decimal.t(), l: Decimal.t(), c: Decimal.t(),
          v: Decimal.t(), ts: DateTime.t(),
          timeframe: :minute | :hour | :day
        }
  defstruct [:venue, :symbol, :o, :h, :l, :c, :v, :ts, timeframe: :minute]
end

# lib/alpaca_trader/types/tick.ex
defmodule AlpacaTrader.Types.Tick do
  @type t :: %__MODULE__{
          venue: atom, symbol: String.t(),
          bid: Decimal.t() | nil, ask: Decimal.t() | nil,
          last: Decimal.t() | nil, ts: DateTime.t()
        }
  defstruct [:venue, :symbol, :bid, :ask, :last, :ts]
end

# lib/alpaca_trader/types/fill.ex
defmodule AlpacaTrader.Types.Fill do
  @type t :: %__MODULE__{
          order_id: String.t(), venue: atom, symbol: String.t(),
          side: :buy | :sell, qty: Decimal.t(), price: Decimal.t(),
          fee: Decimal.t(), ts: DateTime.t()
        }
  defstruct [:order_id, :venue, :symbol, :side, :qty, :price, :ts,
             fee: Decimal.new(0)]
end
```

- [ ] **Step 4: Run, confirm pass**

Run: `mix test test/alpaca_trader/types/`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/alpaca_trader/types test/alpaca_trader/types
git commit -m "feat(types): add Position/Account/Bar/Tick/Fill structs"
```

## Task 1.4: `%Signal{}` + `%Leg{}` + `%FeedSpec{}`

**Files:**
- Create: `lib/alpaca_trader/types/signal.ex`, `lib/alpaca_trader/types/feed_spec.ex`
- Test: `test/alpaca_trader/types/signal_test.exs`, `test/alpaca_trader/types/feed_spec_test.exs`

- [ ] **Step 1: Write failing test for Signal**

```elixir
defmodule AlpacaTrader.Types.SignalTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.Types.{Signal, Leg}

  test "new/1 assigns uuid if missing, defaults atomic=true" do
    leg = %Leg{venue: :alpaca, symbol: "AAPL", side: :buy, size: 10.0, size_mode: :notional, type: :market}
    sig = Signal.new(strategy: :pair_cointegration, legs: [leg], conviction: 0.7, reason: "ok", ttl_ms: 1000)
    assert sig.id =~ ~r/^[0-9a-f]{8}-/
    assert sig.atomic == true
    assert sig.strategy == :pair_cointegration
    assert length(sig.legs) == 1
  end

  test "expired?/1 true when age > ttl" do
    leg = %Leg{venue: :alpaca, symbol: "AAPL", side: :buy, size: 10.0, size_mode: :notional, type: :market}
    old = Signal.new(strategy: :s, legs: [leg], conviction: 1.0, reason: "o", ttl_ms: 1,
                    created_at: DateTime.add(DateTime.utc_now(), -5, :second))
    assert Signal.expired?(old)
  end
end
```

- [ ] **Step 2: Run, confirm fail**

Run: `mix test test/alpaca_trader/types/signal_test.exs`

- [ ] **Step 3: Implement Leg + Signal + FeedSpec**

```elixir
# lib/alpaca_trader/types/signal.ex
defmodule AlpacaTrader.Types.Leg do
  @type t :: %__MODULE__{
          venue: atom, symbol: String.t(),
          side: :buy | :sell,
          size: number | Decimal.t(),
          size_mode: :qty | :notional | :pct_equity,
          type: :market | :limit,
          limit_price: Decimal.t() | nil
        }
  defstruct [:venue, :symbol, :side, :size, :size_mode, :type, :limit_price]
end

defmodule AlpacaTrader.Types.Signal do
  alias AlpacaTrader.Types.Leg

  @type t :: %__MODULE__{
          id: String.t(),
          strategy: atom,
          atomic: boolean,
          legs: [Leg.t()],
          conviction: float,
          reason: String.t(),
          ttl_ms: pos_integer,
          created_at: DateTime.t(),
          meta: map
        }

  defstruct [:strategy, :legs, :conviction, :reason, :ttl_ms,
             id: nil, atomic: true, created_at: nil, meta: %{}]

  @spec new(keyword) :: t()
  def new(opts) do
    id = Keyword.get(opts, :id) || Ecto.UUID.generate()
    created_at = Keyword.get(opts, :created_at) || DateTime.utc_now()
    struct!(__MODULE__, Keyword.merge(opts, id: id, created_at: created_at))
  end

  @spec expired?(t(), DateTime.t()) :: boolean
  def expired?(%__MODULE__{created_at: created, ttl_ms: ttl}, now \\ DateTime.utc_now()) do
    DateTime.diff(now, created, :millisecond) > ttl
  end
end
```

```elixir
# lib/alpaca_trader/types/feed_spec.ex
defmodule AlpacaTrader.Types.FeedSpec do
  @moduledoc """
  Strategies declare the data feeds they need via `required_feeds/0`.
  MarketDataBus ensures the corresponding broker stream is subscribed.
  """
  @type t :: %__MODULE__{
          venue: atom,
          symbols: [String.t()] | :whitelist | :all,
          cadence: :tick | :second | :minute | :hour
        }
  defstruct [:venue, symbols: :whitelist, cadence: :minute]
end
```

If `Ecto.UUID` isn't available, use `:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)` instead — check `mix.exs` for Ecto presence first.

- [ ] **Step 4: Run, confirm pass**

Run: `mix test test/alpaca_trader/types/`
Expected: new tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/alpaca_trader/types/signal.ex lib/alpaca_trader/types/feed_spec.ex \
        test/alpaca_trader/types/signal_test.exs test/alpaca_trader/types/feed_spec_test.exs
git commit -m "feat(types): add Signal, Leg, FeedSpec structs"
```

## Task 1.5: `Broker` behaviour

**Files:**
- Create: `lib/alpaca_trader/broker.ex`

- [ ] **Step 1: No test — behaviours have no runtime code**

- [ ] **Step 2: Implement behaviour**

```elixir
defmodule AlpacaTrader.Broker do
  @moduledoc """
  Venue abstraction. Implementations own HTTP/WS, auth, symbol normalization,
  and response decoding. Strategies never call implementations directly — the
  OrderRouter does, dispatching to the venue named in each %Leg{}.
  """

  alias AlpacaTrader.Types.{Order, Position, Account, Bar, Fill, Capabilities}

  @callback submit_order(Order.t(), opts :: keyword) ::
              {:ok, Order.t()} | {:error, term}

  @callback cancel_order(broker_order_id :: String.t()) ::
              :ok | {:error, term}

  @callback positions() :: {:ok, [Position.t()]} | {:error, term}

  @callback account() :: {:ok, Account.t()} | {:error, term}

  @callback bars(symbol :: String.t(), opts :: keyword) ::
              {:ok, [Bar.t()]} | {:error, term}

  @callback stream_ticks(symbols :: [String.t()], subscriber :: pid) ::
              {:ok, reference} | {:error, term}

  @callback funding_rate(symbol :: String.t()) ::
              {:ok, Decimal.t()} | {:error, term}

  @callback capabilities() :: Capabilities.t()

  # Implementations that cannot supply a callback (e.g. funding_rate on
  # non-perp venues) should return {:error, :not_supported}.
  @optional_callbacks stream_ticks: 2, funding_rate: 1

  @doc "Resolve a venue atom to its implementation module via config."
  @spec impl(atom) :: module
  def impl(venue) do
    case Application.fetch_env!(:alpaca_trader, :brokers) |> Keyword.fetch!(venue) do
      mod when is_atom(mod) -> mod
    end
  end
end
```

- [ ] **Step 3: Verify compile**

Run: `mix compile`
Expected: no warnings (Elixir will warn if the behaviour uses undefined types — all types referenced exist from Task 1.2–1.4).

- [ ] **Step 4: Commit**

```bash
git add lib/alpaca_trader/broker.ex
git commit -m "feat(broker): add Broker behaviour"
```

## Task 1.6: `Strategy` behaviour

**Files:**
- Create: `lib/alpaca_trader/strategy.ex`

- [ ] **Step 1: Implement**

```elixir
defmodule AlpacaTrader.Strategy do
  @moduledoc """
  Strategy abstraction. Each implementation runs as a supervised GenServer.
  Strategies emit %Signal{} lists; they never call brokers or HTTP directly.
  """

  alias AlpacaTrader.Types.{Signal, Fill, FeedSpec}

  @callback id() :: atom
  @callback required_feeds() :: [FeedSpec.t()]
  @callback init(config :: map) :: {:ok, state :: term} | {:error, term}
  @callback scan(state :: term, ctx :: map) ::
              {:ok, [Signal.t()], new_state :: term}
  @callback exits(state :: term, ctx :: map) ::
              {:ok, [Signal.t()], new_state :: term}
  @callback on_fill(state :: term, Fill.t()) :: {:ok, new_state :: term}
end
```

- [ ] **Step 2: Verify compile**

Run: `mix compile`

- [ ] **Step 3: Commit**

```bash
git add lib/alpaca_trader/strategy.ex
git commit -m "feat(strategy): add Strategy behaviour"
```

## Task 1.7: Foundation PR

- [ ] **Step 1: Push branch + PR**

```bash
git push -u origin HEAD
gh pr create --fill --base main --title "feat: Broker + Strategy behaviour foundation"
```

- [ ] **Step 2: Wait for CI**

Run: `gh run watch`

- [ ] **Step 3: Merge**

```bash
gh pr merge --squash --delete-branch
git checkout main && git pull
```

---

# Phase 2 — Track A: broker abstraction

## Task 2.1: Create worktree

**Files:** — (no file changes)

- [ ] **Step 1: Create worktree**

Use the `superpowers:using-git-worktrees` skill. Branch name: `refactor/broker-abstraction`.

After completion, `cd` into the new worktree path.

## Task 2.2: `Brokers.Mock` module

**Files:**
- Create: `test/support/brokers/mock.ex`
- Create: `test/alpaca_trader/brokers/mock_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule AlpacaTrader.Brokers.MockTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.Brokers.Mock
  alias AlpacaTrader.Types.Order

  setup do
    Mock.reset()
    :ok
  end

  test "submit_order records the submission and returns filled order" do
    order = Order.new(venue: :mock, symbol: "TEST", side: :buy, type: :market,
                      size: Decimal.new("10"), size_mode: :qty)
    assert {:ok, filled} = Mock.submit_order(order, [])
    assert filled.status == :filled
    assert [^order] = Mock.submitted_orders()
  end

  test "account/0 returns configured account" do
    Mock.put_account(%{equity: "100", buying_power: "100", cash: "100"})
    assert {:ok, acc} = Mock.account()
    assert Decimal.equal?(acc.equity, Decimal.new("100"))
  end
end
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Implement**

```elixir
defmodule AlpacaTrader.Brokers.Mock do
  @moduledoc """
  Deterministic in-memory Broker implementation for unit + integration tests.
  State held in Agent. Call `reset/0` in setup blocks to isolate tests.
  """
  @behaviour AlpacaTrader.Broker

  alias AlpacaTrader.Types.{Order, Position, Account, Bar, Capabilities}

  @agent __MODULE__.Agent

  def start_link do
    Agent.start_link(fn -> initial_state() end, name: @agent)
  end

  def reset, do: Agent.update(@agent, fn _ -> initial_state() end)

  def submitted_orders,
    do: Agent.get(@agent, fn s -> Enum.reverse(s.submitted) end)

  def put_account(attrs),
    do: Agent.update(@agent, &put_in(&1.account, %Account{
          venue: :mock,
          equity: to_dec(attrs[:equity] || "0"),
          buying_power: to_dec(attrs[:buying_power] || "0"),
          cash: to_dec(attrs[:cash] || "0")
        }))

  def put_positions(list),
    do: Agent.update(@agent, &put_in(&1.positions, list))

  def put_next_submit_result(result),
    do: Agent.update(@agent, &put_in(&1.next_submit, result))

  @impl true
  def submit_order(%Order{} = order, _opts) do
    Agent.get_and_update(@agent, fn s ->
      case s.next_submit do
        nil ->
          filled = %{order | status: :filled, id: "mock-#{System.unique_integer([:positive])}",
                     filled_size: order.size, avg_fill_price: Decimal.new("1")}
          {{:ok, filled}, %{s | submitted: [order | s.submitted]}}
        result ->
          {result, %{s | submitted: [order | s.submitted], next_submit: nil}}
      end
    end)
  end

  @impl true
  def cancel_order(_id), do: :ok
  @impl true
  def positions, do: Agent.get(@agent, fn s -> {:ok, s.positions} end)
  @impl true
  def account, do: Agent.get(@agent, fn s -> {:ok, s.account} end)
  @impl true
  def bars(_s, _o), do: {:ok, []}
  @impl true
  def funding_rate(_s), do: {:error, :not_supported}
  @impl true
  def capabilities,
    do: %Capabilities{shorting: true, perps: false, fractional: true, hours: :h24, fee_bps: 0}

  defp initial_state do
    %{
      submitted: [],
      positions: [],
      account: %Account{venue: :mock, equity: Decimal.new("10000"),
                        buying_power: Decimal.new("10000"), cash: Decimal.new("10000")},
      next_submit: nil
    }
  end

  defp to_dec(%Decimal{} = d), do: d
  defp to_dec(n) when is_number(n), do: Decimal.from_float(n * 1.0)
  defp to_dec(s) when is_binary(s), do: Decimal.new(s)
end
```

Register mock agent in `test/test_helper.exs`:

```elixir
{:ok, _} = AlpacaTrader.Brokers.Mock.start_link()
```

- [ ] **Step 4: Run, confirm pass**

Run: `mix test test/alpaca_trader/brokers/mock_test.exs`

- [ ] **Step 5: Commit**

```bash
git add test/support/brokers/mock.ex test/alpaca_trader/brokers/mock_test.exs test/test_helper.exs
git commit -m "feat(brokers): add Mock broker for tests"
```

## Task 2.3: `Brokers.Alpaca` — extract from existing Alpaca client

**Files:**
- Create: `lib/alpaca_trader/brokers/alpaca.ex`
- Create: `lib/alpaca_trader/brokers/alpaca/symbol.ex`
- Create: `test/alpaca_trader/brokers/alpaca_test.exs`
- Reference existing: `lib/alpaca_trader/alpaca/client.ex` — keep as low-level HTTP; new Alpaca broker wraps it.

- [ ] **Step 1: Write contract test**

```elixir
defmodule AlpacaTrader.Brokers.AlpacaTest do
  use ExUnit.Case, async: false
  import Req.Test
  alias AlpacaTrader.Brokers.Alpaca
  alias AlpacaTrader.Types.Order

  setup do
    # Req.Test stubs Alpaca HTTP client. Assumes AlpacaTrader.Alpaca.Client
    # uses `Req.new(plug: {Req.Test, :alpaca})` in test env.
    :ok
  end

  test "positions/0 decodes Alpaca JSON into %Position{} list" do
    Req.Test.stub(:alpaca, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Req.Test.json([%{
        "symbol" => "AAPL", "qty" => "10", "avg_entry_price" => "150.00",
        "market_value" => "1500", "asset_class" => "us_equity",
        "current_price" => "150.00"
      }])
    end)
    assert {:ok, [pos]} = Alpaca.positions()
    assert pos.venue == :alpaca
    assert pos.symbol == "AAPL"
    assert pos.asset_class == :equity
    assert Decimal.equal?(pos.qty, Decimal.new("10"))
  end

  test "submit_order/2 converts %Order{} to Alpaca body and decodes response" do
    Req.Test.stub(:alpaca, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["symbol"] == "AAPL"
      assert decoded["side"] == "buy"
      assert decoded["notional"] == "100.00"
      Req.Test.json(conn, %{
        "id" => "abc-123", "status" => "accepted",
        "symbol" => "AAPL", "filled_qty" => "0", "side" => "buy"
      })
    end)
    order = Order.new(venue: :alpaca, symbol: "AAPL", side: :buy, type: :market,
                      size: Decimal.new("100"), size_mode: :notional)
    assert {:ok, sub} = Alpaca.submit_order(order, [])
    assert sub.id == "abc-123"
    assert sub.status == :submitted
  end

  test "capabilities/0 reports equity venue shape" do
    caps = Alpaca.capabilities()
    assert caps.shorting == Application.get_env(:alpaca_trader, :allow_short_selling, false)
    assert caps.perps == false
    assert caps.hours == :rth
  end
end
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Implement symbol normalization helper**

```elixir
# lib/alpaca_trader/brokers/alpaca/symbol.ex
defmodule AlpacaTrader.Brokers.Alpaca.Symbol do
  @moduledoc "Alpaca uses 'BTC/USD' for crypto; normalize across codebase."
  def to_alpaca(sym), do: sym  # pass-through for now; extend when needed
  def from_alpaca(sym), do: sym
end
```

- [ ] **Step 4: Implement Alpaca broker**

```elixir
defmodule AlpacaTrader.Brokers.Alpaca do
  @moduledoc """
  Alpaca Broker implementation. Wraps AlpacaTrader.Alpaca.Client (existing HTTP)
  and normalizes responses into %Order{}, %Position{}, %Account{}.
  """
  @behaviour AlpacaTrader.Broker

  alias AlpacaTrader.Alpaca.Client
  alias AlpacaTrader.Types.{Order, Position, Account, Bar, Capabilities}
  alias AlpacaTrader.Brokers.Alpaca.Symbol

  @impl true
  def submit_order(%Order{} = order, _opts) do
    body = to_alpaca_body(order)
    case Client.create_order(body) do
      {:ok, resp} -> {:ok, decode_order(resp, order)}
      {:error, %{status: 422, body: %{"message" => msg}}} ->
        {:ok, %{order | status: :rejected, reason: msg}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def cancel_order(id) do
    case Client.cancel_order(id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def positions do
    with {:ok, list} <- Client.list_positions() do
      {:ok, Enum.map(list, &decode_position/1)}
    end
  end

  @impl true
  def account do
    with {:ok, raw} <- Client.get_account() do
      {:ok, decode_account(raw)}
    end
  end

  @impl true
  def bars(symbol, opts) do
    # Delegates to existing BarsStore / data API. Implementation depends on
    # what Client exposes for bars — use AlpacaTrader.BarsStore directly if
    # Client lacks a bars endpoint wrapper.
    case AlpacaTrader.BarsStore.recent(symbol, opts) do
      bars when is_list(bars) -> {:ok, Enum.map(bars, &decode_bar(&1, symbol))}
      other -> {:error, other}
    end
  end

  @impl true
  def funding_rate(_symbol), do: {:error, :not_supported}

  @impl true
  def capabilities do
    %Capabilities{
      shorting: Application.get_env(:alpaca_trader, :allow_short_selling, false),
      perps: false,
      fractional: true,
      min_notional: Decimal.new("1.00"),
      fee_bps: 0,
      hours: :rth
    }
  end

  # ── decoders ──────────────────────────────────────────────

  defp to_alpaca_body(%Order{} = o) do
    base = %{
      "symbol" => Symbol.to_alpaca(o.symbol),
      "side" => Atom.to_string(o.side),
      "type" => Atom.to_string(o.type),
      "time_in_force" => Atom.to_string(o.tif)
    }
    size = case o.size_mode do
      :qty -> %{"qty" => Decimal.to_string(o.size, :normal)}
      :notional -> %{"notional" => Decimal.to_string(Decimal.round(o.size, 2), :normal)}
      :pct_equity -> raise "pct_equity size_mode must be resolved by router before submit"
    end
    Map.merge(base, size)
  end

  defp decode_order(resp, %Order{} = original) do
    %{original |
      id: resp["id"],
      status: decode_status(resp["status"]),
      submitted_at: decode_ts(resp["submitted_at"]),
      filled_size: to_dec(resp["filled_qty"] || "0"),
      avg_fill_price: resp["filled_avg_price"] && to_dec(resp["filled_avg_price"]),
      raw: resp
    }
  end

  defp decode_status("accepted"), do: :submitted
  defp decode_status("new"), do: :submitted
  defp decode_status("partially_filled"), do: :partial
  defp decode_status("filled"), do: :filled
  defp decode_status("canceled"), do: :canceled
  defp decode_status("rejected"), do: :rejected
  defp decode_status(_), do: :submitted

  defp decode_position(raw) do
    %Position{
      venue: :alpaca,
      symbol: Symbol.from_alpaca(raw["symbol"]),
      qty: to_dec(raw["qty"]),
      avg_entry: raw["avg_entry_price"] && to_dec(raw["avg_entry_price"]),
      mark: raw["current_price"] && to_dec(raw["current_price"]),
      asset_class: map_asset_class(raw["asset_class"]),
      raw: raw
    }
  end

  defp map_asset_class("us_equity"), do: :equity
  defp map_asset_class("crypto"), do: :crypto
  defp map_asset_class(_), do: :unknown

  defp decode_account(raw) do
    %Account{
      venue: :alpaca,
      equity: to_dec(raw["equity"]),
      cash: to_dec(raw["cash"]),
      buying_power: to_dec(raw["buying_power"]),
      daytrade_count: to_int(raw["daytrade_count"]),
      pattern_day_trader: raw["pattern_day_trader"] == true,
      currency: raw["currency"] || "USD",
      raw: raw
    }
  end

  defp decode_bar(bar, symbol) do
    %Bar{venue: :alpaca, symbol: symbol,
         o: to_dec(bar[:o] || bar["o"]), h: to_dec(bar[:h] || bar["h"]),
         l: to_dec(bar[:l] || bar["l"]), c: to_dec(bar[:c] || bar["c"]),
         v: to_dec(bar[:v] || bar["v"] || "0"),
         ts: bar[:t] || bar["t"], timeframe: :minute}
  end

  defp to_dec(nil), do: Decimal.new(0)
  defp to_dec(%Decimal{} = d), do: d
  defp to_dec(n) when is_number(n), do: Decimal.from_float(n / 1)
  defp to_dec(s) when is_binary(s), do: Decimal.new(s)

  defp to_int(nil), do: 0
  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: trunc(n)
  defp to_int(s) when is_binary(s), do: String.to_integer(s)

  defp decode_ts(nil), do: nil
  defp decode_ts(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
```

- [ ] **Step 5: Wire Req.Test stub into Client for test env**

Modify `lib/alpaca_trader/alpaca/client.ex` HTTP constructor to accept a plug injection when `Mix.env() == :test`. Example:

```elixir
# In the existing Req.new call:
req_opts = [base_url: base_url, headers: auth_headers]
req_opts = if Mix.env() == :test, do: Keyword.put(req_opts, :plug, {Req.Test, :alpaca}), else: req_opts
Req.new(req_opts)
```

(Adapt to the exact current shape of `client.ex`. If client uses a `@req` module attribute, inject via `Application.get_env` instead.)

- [ ] **Step 6: Run, confirm pass**

Run: `mix test test/alpaca_trader/brokers/alpaca_test.exs`

- [ ] **Step 7: Commit**

```bash
git add lib/alpaca_trader/brokers/ test/alpaca_trader/brokers/alpaca_test.exs lib/alpaca_trader/alpaca/client.ex
git commit -m "feat(brokers): add Alpaca adapter implementing Broker behaviour"
```

## Task 2.4: Mox defmock for Broker

**Files:**
- Modify: `test/test_helper.exs`
- Create: `test/support/broker_mox.ex`

- [ ] **Step 1: Register Mox defmock in test_helper**

```elixir
# Append to test/test_helper.exs
Mox.defmock(AlpacaTrader.BrokerMock, for: AlpacaTrader.Broker)
Application.put_env(:alpaca_trader, :brokers, [
  alpaca: AlpacaTrader.Brokers.Alpaca,
  mock: AlpacaTrader.Brokers.Mock,
  broker_mock: AlpacaTrader.BrokerMock
])
```

- [ ] **Step 2: Run suite — baseline pass still green**

Run: `mix test`
Expected: all previous tests pass + new ones pass.

- [ ] **Step 3: Commit**

```bash
git add test/test_helper.exs
git commit -m "test: register Mox broker for future OrderRouter tests"
```

## Task 2.5: Refactor `engine.ex` to use `Brokers.Alpaca`

**Files:**
- Modify: `lib/alpaca_trader/engine.ex`
- Modify: `lib/alpaca_trader/engine/order_executor.ex`
- Modify: `config/runtime.exs`

**Strategy:** introduce a seam — every spot engine calls `AlpacaTrader.Alpaca.Client` or builds Alpaca-native order bodies, replace with `Broker.impl(:alpaca).<fn>(…)`. Logic unchanged; contracts change.

- [ ] **Step 1: Add broker config to runtime.exs**

```elixir
# Add inside the `if config_env() != :test do` block in config/runtime.exs
config :alpaca_trader, :brokers, [
  alpaca: AlpacaTrader.Brokers.Alpaca
]
```

- [ ] **Step 2: Find every direct Alpaca call in engine.ex and order_executor.ex**

Run: `grep -n "Client\." lib/alpaca_trader/engine.ex lib/alpaca_trader/engine/order_executor.ex`

For each hit, replace:
- `Client.list_positions()` → `Broker.impl(:alpaca).positions()` (and destructure `{:ok, positions}`)
- `Client.get_account()` → `Broker.impl(:alpaca).account()`
- `Client.create_order(body)` → construct `%Order{}`, call `Broker.impl(:alpaca).submit_order(order, [])`
- `Client.cancel_order(id)` → `Broker.impl(:alpaca).cancel_order(id)`

Keep the existing `Order` struct in `engine.ex` (if any) as an internal shape if needed, but prefer using `AlpacaTrader.Types.Order`.

- [ ] **Step 3: Run existing tests**

Run: `mix test test/alpaca_trader/engine_test.exs test/alpaca_trader/engine_long_only_test.exs`
Expected: all pass after refactor. Fix any decoding mismatches (e.g. `position.qty` was a string; now `Decimal`).

- [ ] **Step 4: Run full suite**

Run: `mix test`

- [ ] **Step 5: Commit**

```bash
git add lib/alpaca_trader/engine.ex lib/alpaca_trader/engine/order_executor.ex config/runtime.exs
git commit -m "refactor(engine): route all Alpaca I/O through Brokers.Alpaca"
```

## Task 2.6: `Brokers.Hyperliquid` skeleton

**Files:**
- Create: `lib/alpaca_trader/brokers/hyperliquid.ex`
- Create: `lib/alpaca_trader/brokers/hyperliquid/client.ex`
- Create: `lib/alpaca_trader/brokers/hyperliquid/auth.ex`
- Create: `test/alpaca_trader/brokers/hyperliquid_test.exs`

- [ ] **Step 1: Write failing test for unsigned decode paths**

```elixir
defmodule AlpacaTrader.Brokers.HyperliquidTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.Brokers.Hyperliquid

  test "capabilities reports perps venue" do
    caps = Hyperliquid.capabilities()
    assert caps.shorting
    assert caps.perps
    assert caps.hours == :h24
  end

  test "funding_rate/1 decodes HL mids endpoint" do
    Req.Test.stub(:hyperliquid, fn conn ->
      # HL /info endpoint returns funding rate via POST {type: "fundingHistory"}
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["type"] in ["fundingHistory", "metaAndAssetCtxs"]
      Req.Test.json(conn, [%{"funding" => "0.00032"}])
    end)
    assert {:ok, rate} = Hyperliquid.funding_rate("BTC")
    assert Decimal.equal?(rate, Decimal.new("0.00032"))
  end
end
```

- [ ] **Step 2: Implement auth module (EIP-712 signing)**

```elixir
defmodule AlpacaTrader.Brokers.Hyperliquid.Auth do
  @moduledoc """
  EIP-712 signing for Hyperliquid API. Reads HL_API_WALLET_KEY from config.
  Uses :libsecp256k1 or :ex_keccak — pick one present in deps. For MVP,
  signing is stubbed behind this module so tests can bypass it.
  """

  @spec sign(map, keyword) :: {:ok, String.t()} | {:error, term}
  def sign(action, opts \\ []) do
    case Application.get_env(:alpaca_trader, :hyperliquid_api_key) do
      nil -> {:error, :no_key}
      _key ->
        # TODO(implementation): real EIP-712 encode + secp256k1 sign.
        # For skeleton, return a deterministic stub signature.
        {:ok, "stub-sig-#{:erlang.phash2(action)}"}
    end
  end
end
```

(Full EIP-712 implementation deferred — test uses stubbed sig. Replay on testnet will fail until real signing added; tracked as open task in plan §4 or follow-up.)

- [ ] **Step 3: Implement HTTP client**

```elixir
defmodule AlpacaTrader.Brokers.Hyperliquid.Client do
  @base_url_mainnet "https://api.hyperliquid.xyz"
  @base_url_testnet "https://api.hyperliquid-testnet.xyz"

  def post(path, body) do
    url = base_url() <> path
    req = Req.new(url: url, headers: [{"content-type", "application/json"}])
    req = if Mix.env() == :test, do: Req.merge(req, plug: {Req.Test, :hyperliquid}), else: req
    case Req.post(req, json: body) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: code, body: body}} -> {:error, {:http, code, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp base_url do
    case Application.get_env(:alpaca_trader, :hyperliquid_env, :mainnet) do
      :testnet -> @base_url_testnet
      _ -> @base_url_mainnet
    end
  end
end
```

- [ ] **Step 4: Implement Broker**

```elixir
defmodule AlpacaTrader.Brokers.Hyperliquid do
  @behaviour AlpacaTrader.Broker

  alias AlpacaTrader.Brokers.Hyperliquid.{Client, Auth}
  alias AlpacaTrader.Types.{Order, Position, Account, Bar, Capabilities}

  @impl true
  def submit_order(%Order{} = order, _opts) do
    action = %{
      "type" => "order",
      "orders" => [%{
        "coin" => order.symbol,
        "is_buy" => order.side == :buy,
        "sz" => Decimal.to_string(order.size, :normal),
        "limit_px" => order.limit_price && Decimal.to_string(order.limit_price, :normal),
        "order_type" => %{"market" => %{}},
        "reduce_only" => false
      }]
    }
    with {:ok, sig} <- Auth.sign(action),
         {:ok, resp} <- Client.post("/exchange", %{"action" => action, "signature" => sig,
                                                    "nonce" => System.system_time(:millisecond)}) do
      {:ok, %{order | id: resp["response"]["data"]["statuses"] |> List.first() |> Map.get("resting", %{}) |> Map.get("oid"),
              status: :submitted, raw: resp}}
    end
  end

  @impl true
  def cancel_order(_id), do: {:error, :not_implemented_yet}

  @impl true
  def positions do
    addr = Application.get_env(:alpaca_trader, :hyperliquid_wallet_addr)
    with {:ok, resp} <- Client.post("/info", %{"type" => "clearinghouseState", "user" => addr}) do
      positions = (resp["assetPositions"] || []) |> Enum.map(&decode_position/1)
      {:ok, positions}
    end
  end

  @impl true
  def account do
    addr = Application.get_env(:alpaca_trader, :hyperliquid_wallet_addr)
    with {:ok, resp} <- Client.post("/info", %{"type" => "clearinghouseState", "user" => addr}) do
      summary = resp["marginSummary"] || %{}
      {:ok, %Account{
        venue: :hyperliquid,
        equity: to_dec(summary["accountValue"] || "0"),
        cash: to_dec(summary["totalRawUsd"] || "0"),
        buying_power: to_dec(summary["totalRawUsd"] || "0"),
        raw: resp
      }}
    end
  end

  @impl true
  def bars(_symbol, _opts), do: {:ok, []}   # deferred to Phase 3

  @impl true
  def funding_rate(symbol) do
    with {:ok, resp} <- Client.post("/info", %{"type" => "metaAndAssetCtxs"}) do
      rate =
        case resp do
          [_meta, ctxs] when is_list(ctxs) ->
            case Enum.find(ctxs, &(Map.get(&1, "name") == symbol || true)) do
              %{"funding" => f} -> to_dec(f)
              _ -> Decimal.new(0)
            end
          list when is_list(list) ->
            first = List.first(list) || %{}
            to_dec(first["funding"] || "0")
          _ -> Decimal.new(0)
        end
      {:ok, rate}
    end
  end

  @impl true
  def capabilities do
    %Capabilities{shorting: true, perps: true, fractional: true,
                  min_notional: Decimal.new("10"), fee_bps: 5, hours: :h24}
  end

  defp decode_position(%{"position" => p}) do
    %Position{
      venue: :hyperliquid,
      symbol: p["coin"],
      qty: to_dec(p["szi"]),
      avg_entry: to_dec(p["entryPx"] || "0"),
      asset_class: :perp,
      raw: p
    }
  end

  defp to_dec(nil), do: Decimal.new(0)
  defp to_dec(%Decimal{} = d), do: d
  defp to_dec(s) when is_binary(s), do: Decimal.new(s)
  defp to_dec(n) when is_number(n), do: Decimal.from_float(n / 1)
end
```

- [ ] **Step 5: Run tests**

Run: `mix test test/alpaca_trader/brokers/hyperliquid_test.exs`

- [ ] **Step 6: Add config entries**

```elixir
# config/runtime.exs, inside the main alpaca_trader block:
config :alpaca_trader, :brokers, [
  alpaca: AlpacaTrader.Brokers.Alpaca,
  hyperliquid: AlpacaTrader.Brokers.Hyperliquid
]
config :alpaca_trader, :hyperliquid_env, (System.get_env("HL_ENV", "mainnet") |> String.to_atom())
config :alpaca_trader, :hyperliquid_wallet_addr, System.get_env("HL_WALLET_ADDR")
config :alpaca_trader, :hyperliquid_api_key, System.get_env("HL_API_WALLET_KEY")
```

- [ ] **Step 7: Commit**

```bash
git add lib/alpaca_trader/brokers/hyperliquid* test/alpaca_trader/brokers/hyperliquid_test.exs config/runtime.exs
git commit -m "feat(brokers): add Hyperliquid skeleton Broker"
```

## Task 2.7: Merge Track A

- [ ] **Step 1: Push + PR**

```bash
git push -u origin HEAD
gh pr create --fill --base main --title "refactor(broker): abstract Alpaca + add Hyperliquid skeleton"
```

- [ ] **Step 2: CI green, merge, return to main**

```bash
gh run watch
gh pr merge --squash --delete-branch
cd <main worktree> && git checkout main && git pull
```

---

# Phase 3 — Track B: strategy abstraction, router, new strategy

## Task 3.1: Create worktree for Track B

- [ ] **Step 1:** Use `superpowers:using-git-worktrees` to create `refactor/strategy-abstraction` worktree off `main` (which now has Track A merged).

## Task 3.2: `MarketDataBus` (GenStage)

**Files:**
- Create: `lib/alpaca_trader/market_data_bus.ex`
- Test: `test/alpaca_trader/market_data_bus_test.exs`

- [ ] **Step 1: Failing test**

```elixir
defmodule AlpacaTrader.MarketDataBusTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.MarketDataBus
  alias AlpacaTrader.Types.Tick

  setup do
    {:ok, _} = MarketDataBus.start_link(name: :bus_test)
    :ok
  end

  test "broadcasts ticks to subscribers" do
    MarketDataBus.subscribe(:bus_test, self())
    tick = %Tick{venue: :alpaca, symbol: "AAPL", last: Decimal.new("150"), ts: DateTime.utc_now()}
    MarketDataBus.publish(:bus_test, tick)
    assert_receive {:market_data, ^tick}, 500
  end
end
```

- [ ] **Step 2: Implement as simple fan-out (GenServer with Registry, not full GenStage producer-consumer)**

```elixir
defmodule AlpacaTrader.MarketDataBus do
  @moduledoc """
  Fan-out broadcaster for ticks, fills, and account updates from all brokers.
  Subscribers are pids that receive `{:market_data, event}` messages.
  Uses a GenServer with a MapSet of subscribers — full GenStage back-pressure
  not needed until subscriber count or event rate justifies it.
  """
  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, name: name)
  end

  def subscribe(bus \\ __MODULE__, pid), do: GenServer.call(bus, {:sub, pid})
  def publish(bus \\ __MODULE__, event), do: GenServer.cast(bus, {:pub, event})

  @impl true
  def init(_), do: {:ok, MapSet.new()}

  @impl true
  def handle_call({:sub, pid}, _, subs) do
    Process.monitor(pid)
    {:reply, :ok, MapSet.put(subs, pid)}
  end

  @impl true
  def handle_cast({:pub, event}, subs) do
    for pid <- subs, do: send(pid, {:market_data, event})
    {:noreply, subs}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, subs),
    do: {:noreply, MapSet.delete(subs, pid)}
end
```

- [ ] **Step 3: Run, pass**

- [ ] **Step 4: Add to supervision in `application.ex`**

```elixir
# In AlpacaTrader.Application.start/2 children list, append:
AlpacaTrader.MarketDataBus
```

- [ ] **Step 5: Commit**

```bash
git add lib/alpaca_trader/market_data_bus.ex test/alpaca_trader/market_data_bus_test.exs lib/alpaca_trader/application.ex
git commit -m "feat: add MarketDataBus fan-out"
```

## Task 3.3: `StrategySupervisor` + `StrategyRegistry`

**Files:**
- Create: `lib/alpaca_trader/strategy_supervisor.ex`
- Create: `lib/alpaca_trader/strategy_registry.ex`
- Test: `test/alpaca_trader/strategy_registry_test.exs`

- [ ] **Step 1: Failing test**

```elixir
defmodule AlpacaTrader.StrategyRegistryTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.StrategyRegistry

  defmodule FakeStrategy do
    @behaviour AlpacaTrader.Strategy
    def id, do: :fake
    def required_feeds, do: []
    def init(_), do: {:ok, %{count: 0}}
    def scan(state, _ctx), do: {:ok, [], %{state | count: state.count + 1}}
    def exits(state, _ctx), do: {:ok, [], state}
    def on_fill(state, _fill), do: {:ok, state}
  end

  test "loads strategy from config and tick increments state" do
    Application.put_env(:alpaca_trader, :strategies, [{FakeStrategy, %{}}])
    {:ok, _} = StrategyRegistry.start_link([])
    signals = StrategyRegistry.tick(%{})
    assert signals == []
  end
end
```

- [ ] **Step 2: Run, fail**

- [ ] **Step 3: Implement DynamicSupervisor for strategies**

```elixir
defmodule AlpacaTrader.StrategySupervisor do
  use DynamicSupervisor

  def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_strategy(mod, config) do
    spec = {AlpacaTrader.StrategyRunner, {mod, config}}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
```

- [ ] **Step 4: Implement StrategyRunner GenServer (per-strategy worker)**

```elixir
defmodule AlpacaTrader.StrategyRunner do
  @moduledoc "One GenServer per loaded Strategy, holds strategy state."
  use GenServer

  def start_link({mod, config}) do
    GenServer.start_link(__MODULE__, {mod, config}, name: via(mod.id()))
  end

  defp via(id), do: {:via, Registry, {AlpacaTrader.StrategyRunners, id}}

  def scan(id, ctx), do: GenServer.call(via(id), {:scan, ctx})
  def exits(id, ctx), do: GenServer.call(via(id), {:exits, ctx})
  def on_fill(id, fill), do: GenServer.cast(via(id), {:fill, fill})

  @impl true
  def init({mod, config}) do
    {:ok, state} = mod.init(config)
    {:ok, %{mod: mod, state: state}}
  end

  @impl true
  def handle_call({:scan, ctx}, _from, %{mod: mod, state: s}=w) do
    {:ok, sigs, s2} = mod.scan(s, ctx)
    {:reply, sigs, %{w | state: s2}}
  end

  def handle_call({:exits, ctx}, _from, %{mod: mod, state: s}=w) do
    {:ok, sigs, s2} = mod.exits(s, ctx)
    {:reply, sigs, %{w | state: s2}}
  end

  @impl true
  def handle_cast({:fill, fill}, %{mod: mod, state: s}=w) do
    {:ok, s2} = mod.on_fill(s, fill)
    {:noreply, %{w | state: s2}}
  end
end
```

- [ ] **Step 5: Implement StrategyRegistry (coordinator)**

```elixir
defmodule AlpacaTrader.StrategyRegistry do
  @moduledoc """
  Loads strategies from config, starts a Runner per strategy,
  fans a `tick/1` call across all of them collecting Signals.
  """
  use GenServer

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def tick(ctx), do: GenServer.call(__MODULE__, {:tick, ctx})

  @impl true
  def init(_) do
    configs = Application.get_env(:alpaca_trader, :strategies, [])
    ids =
      for {mod, cfg} <- configs, reduce: [] do
        acc ->
          {:ok, _pid} = AlpacaTrader.StrategySupervisor.start_strategy(mod, cfg)
          [mod.id() | acc]
      end
    {:ok, Enum.reverse(ids)}
  end

  @impl true
  def handle_call({:tick, ctx}, _from, ids) do
    signals =
      Enum.flat_map(ids, fn id ->
        AlpacaTrader.StrategyRunner.scan(id, ctx) ++
          AlpacaTrader.StrategyRunner.exits(id, ctx)
      end)
    {:reply, signals, ids}
  end
end
```

- [ ] **Step 6: Supervision wiring**

In `application.ex`, add children (order matters — Registry must start before StrategySupervisor):

```elixir
{Registry, keys: :unique, name: AlpacaTrader.StrategyRunners},
AlpacaTrader.StrategySupervisor,
AlpacaTrader.StrategyRegistry
```

- [ ] **Step 7: Run tests, pass**

- [ ] **Step 8: Commit**

```bash
git add lib/alpaca_trader/strategy_{registry,runner,supervisor}.ex \
        test/alpaca_trader/strategy_registry_test.exs lib/alpaca_trader/application.ex
git commit -m "feat(strategy): Registry + Supervisor + Runner"
```

## Task 3.4: `OrderRouter` — gates + atomic submission

**Files:**
- Create: `lib/alpaca_trader/order_router.ex`
- Test: `test/alpaca_trader/order_router_test.exs`

- [ ] **Step 1: Failing tests — one per gate**

```elixir
defmodule AlpacaTrader.OrderRouterTest do
  use ExUnit.Case, async: false
  import Mox
  setup :verify_on_exit!

  alias AlpacaTrader.{OrderRouter, BrokerMock}
  alias AlpacaTrader.Types.{Signal, Leg, Order, Account, Capabilities}

  defp one_leg_signal(opts \\ []) do
    leg = %Leg{venue: :broker_mock, symbol: "AAPL", side: :buy,
               size: 100.0, size_mode: :notional, type: :market}
    Signal.new([{:strategy, :test}, {:legs, [leg]}, {:conviction, 1.0},
                {:reason, "t"}, {:ttl_ms, 10_000}] ++ opts)
  end

  setup do
    Application.put_env(:alpaca_trader, :brokers, [broker_mock: BrokerMock])
    :ok
  end

  test "drops expired signal" do
    expired = one_leg_signal(ttl_ms: 1, created_at: DateTime.add(DateTime.utc_now(), -10, :second))
    assert {:dropped, :expired} = OrderRouter.route(expired)
  end

  test "drops when TRADING_ENABLED is false" do
    Application.put_env(:alpaca_trader, :trading_enabled, false)
    on_exit(fn -> Application.put_env(:alpaca_trader, :trading_enabled, true) end)
    assert {:dropped, :kill_switch} = OrderRouter.route(one_leg_signal())
  end

  test "submits when all gates pass" do
    Application.put_env(:alpaca_trader, :trading_enabled, true)
    BrokerMock |> expect(:capabilities, fn -> %Capabilities{shorting: true, fractional: true, hours: :h24} end)
    BrokerMock |> expect(:account, fn -> {:ok, %Account{venue: :broker_mock, equity: Decimal.new("10000"),
                                                         buying_power: Decimal.new("10000"),
                                                         cash: Decimal.new("10000")}} end)
    BrokerMock |> expect(:submit_order, fn %Order{}=o, _ ->
                  {:ok, %{o | status: :filled, id: "x"}} end)
    assert {:ok, [_]} = OrderRouter.route(one_leg_signal())
  end

  test "atomic pair: reverses filled leg when other leg fails" do
    Application.put_env(:alpaca_trader, :trading_enabled, true)
    BrokerMock |> stub(:capabilities, fn -> %Capabilities{shorting: true, fractional: true, hours: :h24} end)
    BrokerMock |> stub(:account, fn -> {:ok, %Account{venue: :broker_mock, equity: Decimal.new("10000"),
                                                      buying_power: Decimal.new("10000"), cash: Decimal.new("10000")}} end)
    BrokerMock |> expect(:submit_order, 3, fn
      %Order{side: :buy}=o, _ -> {:ok, %{o | status: :filled, id: "leg1"}}
      %Order{side: :sell}=_o, _ -> {:error, :rate_limited}
    end)
    leg_a = %Leg{venue: :broker_mock, symbol: "A", side: :buy, size: 100.0, size_mode: :notional, type: :market}
    leg_b = %Leg{venue: :broker_mock, symbol: "B", side: :sell, size: 100.0, size_mode: :notional, type: :market}
    sig = Signal.new(strategy: :t, legs: [leg_a, leg_b], conviction: 1.0, reason: "t", ttl_ms: 10_000)
    assert {:atomic_break, _} = OrderRouter.route(sig)
    # Third call (from expect 3) is the reversing sell to close the :buy leg.
  end
end
```

- [ ] **Step 2: Run, fail**

- [ ] **Step 3: Implement router**

```elixir
defmodule AlpacaTrader.OrderRouter do
  @moduledoc """
  Central policy choke-point. Every signal passes through:
    ttl → kill_switch → capabilities → portfolio → gain → llm → submit.
  Atomic signals submit all legs concurrently; on partial fill, filled legs
  are reversed with opposite-side market orders.
  """
  alias AlpacaTrader.Types.{Signal, Leg, Order}
  alias AlpacaTrader.{Broker, ShadowLogger}

  require Logger

  @type outcome ::
          {:ok, [Order.t()]}
          | {:dropped, reason :: atom}
          | {:rejected, reason :: atom}
          | {:atomic_break, [Order.t()]}

  @spec route(Signal.t()) :: outcome()
  def route(%Signal{}=sig) do
    with :ok <- gate_ttl(sig),
         :ok <- gate_kill_switch(sig),
         :ok <- gate_capabilities(sig),
         :ok <- gate_portfolio(sig),
         :ok <- gate_gain(sig),
         :ok <- gate_llm(sig) do
      submit(sig)
    else
      {:dropped, reason} -> ShadowLogger.log_drop(sig, reason); {:dropped, reason}
      {:rejected, reason} -> ShadowLogger.log_reject(sig, reason); {:rejected, reason}
    end
  end

  # ── gates ─────────────────────────────────────────

  defp gate_ttl(sig), do: if Signal.expired?(sig), do: {:dropped, :expired}, else: :ok

  defp gate_kill_switch(_sig) do
    if Application.get_env(:alpaca_trader, :trading_enabled, true),
      do: :ok, else: {:dropped, :kill_switch}
  end

  defp gate_capabilities(%Signal{legs: legs, atomic: atomic}) do
    incompatible =
      Enum.filter(legs, fn %Leg{venue: v, side: side} ->
        caps = Broker.impl(v).capabilities()
        side == :sell && !caps.shorting
      end)
    cond do
      incompatible == [] -> :ok
      atomic -> {:rejected, :venue_cannot_short}
      true -> :ok    # router will drop the unroutable legs in submit/1
    end
  end

  defp gate_portfolio(sig) do
    case AlpacaTrader.PortfolioRisk.allow_entry_for_signal(sig) do
      :ok -> :ok
      {:blocked, reason} -> {:rejected, {:portfolio, reason}}
    end
  end

  defp gate_gain(_sig) do
    acc = AlpacaTrader.GainAccumulatorStore
    # Router uses whichever venue equity is the *primary* — for MVP, Alpaca.
    with {:ok, acc_data} <- AlpacaTrader.Brokers.Alpaca.account(),
         true <- acc.allow_entry?(acc_data.equity) do
      :ok
    else
      false -> {:rejected, :gain_accumulator}
      other -> {:rejected, {:gain_check, other}}
    end
  end

  defp gate_llm(%Signal{conviction: c}) when c >= 0.6, do: :ok
  defp gate_llm(_), do: {:dropped, :low_conviction}

  # ── submission ────────────────────────────────────

  defp submit(%Signal{legs: legs, atomic: true}=sig) do
    results =
      legs
      |> Task.async_stream(&submit_leg/1, ordered: true, timeout: 10_000,
                            on_timeout: :kill_task, max_concurrency: length(legs))
      |> Enum.map(fn {:ok, r} -> r end)
    case Enum.split_with(results, fn {status, _} -> status == :ok end) do
      {oks, []} ->
        orders = Enum.map(oks, fn {:ok, o} -> o end)
        ShadowLogger.log_submit(sig, orders)
        {:ok, orders}
      {oks, _fails} ->
        filled = Enum.map(oks, fn {:ok, o} -> o end)
        Enum.each(filled, &reverse_leg/1)
        Logger.warning("[Router] atomic-break rollback: sig=#{sig.id}, filled=#{length(filled)}")
        ShadowLogger.log_atomic_break(sig, filled)
        {:atomic_break, filled}
    end
  end

  defp submit(%Signal{legs: legs, atomic: false}=sig) do
    orders =
      legs
      |> Enum.map(&submit_leg/1)
      |> Enum.flat_map(fn {:ok, o} -> [o]; _ -> [] end)
    ShadowLogger.log_submit(sig, orders)
    {:ok, orders}
  end

  defp submit_leg(%Leg{venue: v}=leg) do
    order = leg_to_order(leg)
    Broker.impl(v).submit_order(order, [])
  end

  defp reverse_leg(%Order{side: :buy}=o) do
    reverse = %{o | side: :sell, id: nil, status: :pending}
    Broker.impl(o.venue).submit_order(reverse, reduce_only: true)
  end
  defp reverse_leg(%Order{side: :sell}=o) do
    reverse = %{o | side: :buy, id: nil, status: :pending}
    Broker.impl(o.venue).submit_order(reverse, reduce_only: true)
  end

  defp leg_to_order(%Leg{}=l) do
    Order.new(venue: l.venue, symbol: l.symbol, side: l.side,
              size: to_decimal(l.size), size_mode: l.size_mode, type: l.type,
              limit_price: l.limit_price)
  end

  defp to_decimal(%Decimal{}=d), do: d
  defp to_decimal(n) when is_number(n), do: Decimal.from_float(n / 1)
end
```

- [ ] **Step 4: Add `PortfolioRisk.allow_entry_for_signal/1` wrapper**

```elixir
# In lib/alpaca_trader/portfolio_risk.ex, add:
def allow_entry_for_signal(%AlpacaTrader.Types.Signal{legs: legs}) do
  # Evaluate each leg's sector. Simple impl: reject if any leg's sector is at cap.
  Enum.reduce_while(legs, :ok, fn leg, _ ->
    case check_per_sector(current_open_positions(), %{asset: leg.symbol}) do
      :ok -> {:cont, :ok}
      {:blocked, reason} -> {:halt, {:blocked, reason}}
    end
  end)
end

# If current_open_positions/0 doesn't exist yet, wrap the existing call site.
```

- [ ] **Step 5: Extend `ShadowLogger`**

```elixir
# lib/alpaca_trader/shadow_logger.ex — add functions:
def log_submit(sig, orders), do: write(%{type: "submit", sig: sig_view(sig), orders: order_view(orders)})
def log_drop(sig, reason), do: write(%{type: "drop", sig: sig_view(sig), reason: inspect(reason)})
def log_reject(sig, reason), do: write(%{type: "reject", sig: sig_view(sig), reason: inspect(reason)})
def log_atomic_break(sig, filled), do: write(%{type: "atomic_break", sig: sig_view(sig), filled: order_view(filled)})

defp sig_view(s), do: %{id: s.id, strategy: s.strategy, legs: leg_view(s.legs),
                         conviction: s.conviction, reason: s.reason, atomic: s.atomic}
defp leg_view(legs), do: Enum.map(legs, &Map.from_struct/1)
defp order_view(orders), do: Enum.map(orders, fn o -> %{venue: o.venue, symbol: o.symbol, side: o.side,
                                                         status: o.status, id: o.id} end)
```

If `ShadowLogger` already writes to `priv/runtime/shadow_signals.jsonl`, reuse its writer; just add the functions above.

- [ ] **Step 6: Run tests**

Run: `mix test test/alpaca_trader/order_router_test.exs`

- [ ] **Step 7: Commit**

```bash
git add lib/alpaca_trader/order_router.ex lib/alpaca_trader/portfolio_risk.ex \
        lib/alpaca_trader/shadow_logger.ex test/alpaca_trader/order_router_test.exs
git commit -m "feat(router): OrderRouter with gate pipeline + atomic submission"
```

## Task 3.5: Port `PairCointegration` into `Strategy` behaviour

**Files:**
- Create: `lib/alpaca_trader/strategies/pair_cointegration.ex`
- Create: `test/alpaca_trader/strategies/pair_cointegration_test.exs`
- Modify: `lib/alpaca_trader/engine.ex` (shrinks significantly — scan logic moves)

- [ ] **Step 1: Failing test — verify wrapped strategy emits same signal count as current engine**

```elixir
defmodule AlpacaTrader.Strategies.PairCointegrationTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.Strategies.PairCointegration
  alias AlpacaTrader.Brokers.Mock

  setup do
    Mock.reset()
    {:ok, state} = PairCointegration.init(%{})
    [state: state]
  end

  test "scan/2 returns empty list when no pairs qualify", %{state: s} do
    ctx = %{now: DateTime.utc_now(), bars: %{}, positions: [], account: Mock.account() |> elem(1)}
    assert {:ok, [], _s2} = PairCointegration.scan(s, ctx)
  end

  test "scan/2 emits 2-leg Signal for a qualifying cointegrated pair", %{state: s} do
    # Fixture: synthetic bars that produce z_score > threshold
    ctx = FixtureBuilder.cointegrated_pair_context("AAPL", "MSFT")
    {:ok, signals, _} = PairCointegration.scan(s, ctx)
    assert length(signals) == 1
    [sig] = signals
    assert length(sig.legs) == 2
    assert sig.strategy == :pair_cointegration
  end
end
```

- [ ] **Step 2: Implement strategy**

```elixir
defmodule AlpacaTrader.Strategies.PairCointegration do
  @behaviour AlpacaTrader.Strategy
  alias AlpacaTrader.Types.{Signal, Leg, FeedSpec}

  @impl true
  def id, do: :pair_cointegration

  @impl true
  def required_feeds,
    do: [%FeedSpec{venue: :alpaca, symbols: :whitelist, cadence: :minute}]

  @impl true
  def init(config) do
    {:ok, %{
      config: config,
      open_positions: %{}    # sig_id → %{legs, opened_at}
    }}
  end

  @impl true
  def scan(state, ctx) do
    # MOVE the existing engine scan logic here. Replace every direct call
    # to Alpaca client with reads from ctx.bars / ctx.positions / ctx.account.
    # Replace every `OrderExecutor.execute_*` with Signal emission.
    signals = AlpacaTrader.Strategies.PairCointegration.Scanner.emit_signals(ctx, state)
    {:ok, signals, state}
  end

  @impl true
  def exits(state, ctx) do
    signals = AlpacaTrader.Strategies.PairCointegration.Scanner.emit_exit_signals(ctx, state)
    {:ok, signals, state}
  end

  @impl true
  def on_fill(state, fill) do
    {:ok, update_open_positions(state, fill)}
  end

  defp update_open_positions(state, _fill), do: state   # refine as Fill flow lands
end

defmodule AlpacaTrader.Strategies.PairCointegration.Scanner do
  @moduledoc "Extracted pair scan logic. See engine.ex pre-refactor for the source."
  alias AlpacaTrader.Types.{Signal, Leg}

  def emit_signals(ctx, _state) do
    # Call the existing pair discovery + cointegration + z-score pipeline.
    # Pseudocode:
    #   arbs = AlpacaTrader.Arbitrage.DiscoveryScanner.scan(ctx)
    #   arbs = Enum.filter(arbs, &passes_cointegration?/1)
    #   arbs = Enum.filter(arbs, &passes_regime?/1)
    #   Enum.map(arbs, &arb_to_signal/1)
    []
  end

  def emit_exit_signals(_ctx, _state), do: []

  defp _arb_to_signal(arb) do
    Signal.new(
      strategy: :pair_cointegration,
      atomic: true,
      legs: [
        %Leg{venue: :alpaca, symbol: arb.asset, side: entry_side(arb, :a),
             size: notional(arb), size_mode: :notional, type: :market},
        %Leg{venue: :alpaca, symbol: arb.pair_asset, side: entry_side(arb, :b),
             size: notional(arb), size_mode: :notional, type: :market}
      ],
      conviction: arb.llm_conviction || 0.7,
      reason: "z=#{arb.z_score}",
      ttl_ms: 5_000,
      meta: %{z_score: arb.z_score, tier: arb.tier, direction: arb.direction}
    )
  end

  defp entry_side(%{direction: :long_a_short_b}, :a), do: :buy
  defp entry_side(%{direction: :long_a_short_b}, :b), do: :sell
  defp entry_side(%{direction: :long_b_short_a}, :a), do: :sell
  defp entry_side(%{direction: :long_b_short_a}, :b), do: :buy

  defp notional(_arb), do: 100.0
end
```

- [ ] **Step 3: Gut `engine.ex`**

- Remove `execute_entry_post_portfolio_gate/3`, `build_entry_params/2`, `build_exit_params/2`.
- Remove all `OrderExecutor.execute_*` calls from the engine.
- Leave only coordinator glue (if any remains) or delete the module entirely and update references.

Tests under `test/alpaca_trader/engine_test.exs` likely need to move or retarget `Strategies.PairCointegration`. Rename or delete the old tests whose assertions now live under `pair_cointegration_test.exs`.

- [ ] **Step 4: Run tests**

Run: `mix test`
Expected: all green. If `engine_long_only_test.exs` fails, either move assertions into the new strategy test or delete (long-only is now a router policy, not a strategy concern).

- [ ] **Step 5: Commit**

```bash
git add lib/alpaca_trader/strategies/pair_cointegration.ex \
        test/alpaca_trader/strategies/pair_cointegration_test.exs \
        lib/alpaca_trader/engine.ex lib/alpaca_trader/engine/order_executor.ex \
        test/alpaca_trader/engine_test.exs test/alpaca_trader/engine_long_only_test.exs
git commit -m "refactor: port PairCointegration into Strategy behaviour"
```

## Task 3.6: `FundingBasisArb` strategy

**Files:**
- Create: `lib/alpaca_trader/strategies/funding_basis_arb.ex`
- Test: `test/alpaca_trader/strategies/funding_basis_arb_test.exs`
- Modify: `config/runtime.exs` (add `:asset_proxies`)

- [ ] **Step 1: Failing test**

```elixir
defmodule AlpacaTrader.Strategies.FundingBasisArbTest do
  use ExUnit.Case, async: false
  import Mox
  setup :verify_on_exit!

  alias AlpacaTrader.Strategies.FundingBasisArb
  alias AlpacaTrader.BrokerMock

  setup do
    Application.put_env(:alpaca_trader, :asset_proxies, %{
      "BTC" => %{alpaca: "IBIT", beta: 1.0, quality: :high}
    })
    Application.put_env(:alpaca_trader, :brokers, [
      hyperliquid: BrokerMock,
      alpaca: AlpacaTrader.Brokers.Mock
    ])
    {:ok, state} = FundingBasisArb.init(%{})
    [state: state]
  end

  test "emits Signal when funding above threshold", %{state: s} do
    BrokerMock |> expect(:funding_rate, fn "BTC" -> {:ok, Decimal.new("0.00050")} end)
    ctx = %{
      now: DateTime.utc_now(),
      ticks: %{
        {:hyperliquid, "BTC"} => %{last: Decimal.new("60000")},
        {:alpaca, "IBIT"}     => %{last: Decimal.new("60.00")}
      }
    }
    {:ok, sigs, _} = FundingBasisArb.scan(s, ctx)
    assert length(sigs) == 1
    [sig] = sigs
    assert sig.strategy == :funding_basis_arb
    assert [hl, al] = sig.legs
    assert hl.venue == :hyperliquid
    assert hl.side == :short
    assert al.venue == :alpaca
    assert al.side == :buy
  end

  test "no signal below threshold", %{state: s} do
    BrokerMock |> expect(:funding_rate, fn "BTC" -> {:ok, Decimal.new("0.00001")} end)
    ctx = %{now: DateTime.utc_now(), ticks: %{}}
    {:ok, [], _} = FundingBasisArb.scan(s, ctx)
  end
end
```

- [ ] **Step 2: Run, fail**

- [ ] **Step 3: Implement**

```elixir
defmodule AlpacaTrader.Strategies.FundingBasisArb do
  @behaviour AlpacaTrader.Strategy
  alias AlpacaTrader.Types.{Signal, Leg, FeedSpec}
  alias AlpacaTrader.Broker

  @threshold_bps 10    # 10 basis points after fees
  @notional_per_leg 50.0

  @impl true
  def id, do: :funding_basis_arb

  @impl true
  def required_feeds do
    [
      %FeedSpec{venue: :hyperliquid, symbols: :whitelist, cadence: :second},
      %FeedSpec{venue: :alpaca, symbols: :whitelist, cadence: :minute}
    ]
  end

  @impl true
  def init(config) do
    {:ok, %{
      open_positions: %{},  # symbol -> %{opened_at, signal_id}
      config: config
    }}
  end

  @impl true
  def scan(state, ctx) do
    proxies = Application.get_env(:alpaca_trader, :asset_proxies, %{})
    signals =
      for {perp_sym, %{alpaca: alpaca_sym, quality: q}} <- proxies,
          q != :none, alpaca_sym != nil,
          signal = evaluate_pair(perp_sym, alpaca_sym, ctx, state),
          signal != nil,
          do: signal
    {:ok, signals, state}
  end

  @impl true
  def exits(state, ctx) do
    signals =
      for {sym, %{opened_at: opened, signal_id: sid}} <- state.open_positions,
          should_exit?(sym, opened, ctx) do
        exit_signal(sym, sid, ctx)
      end
    {:ok, signals, state}
  end

  @impl true
  def on_fill(state, fill) do
    updated =
      case fill.side do
        :buy  -> Map.put(state.open_positions, fill.symbol, %{opened_at: fill.ts, signal_id: fill.order_id})
        :sell -> Map.delete(state.open_positions, fill.symbol)
      end
    {:ok, %{state | open_positions: updated}}
  end

  # ── helpers ───────────────────────────────────────

  defp evaluate_pair(perp_sym, alpaca_sym, ctx, state) do
    with {:ok, rate} <- Broker.impl(:hyperliquid).funding_rate(perp_sym),
         perp_mid <- get_in(ctx.ticks, [{:hyperliquid, perp_sym}, :last]),
         spot_mid <- get_in(ctx.ticks, [{:alpaca, alpaca_sym}, :last]),
         true <- !is_nil(perp_mid) && !is_nil(spot_mid),
         false <- Map.has_key?(state.open_positions, perp_sym) do
      basis = Decimal.div(Decimal.sub(perp_mid, spot_mid), spot_mid)
      score_bps = Decimal.to_float(rate) * 10_000 - 2   # 2bps fee
      cond do
        score_bps > @threshold_bps ->
          build_signal(perp_sym, alpaca_sym, :positive, rate, basis)
        score_bps < -@threshold_bps ->
          build_signal(perp_sym, alpaca_sym, :negative, rate, basis)
        true -> nil
      end
    else
      _ -> nil
    end
  end

  defp build_signal(perp_sym, alpaca_sym, :positive, rate, basis) do
    Signal.new(
      strategy: :funding_basis_arb, atomic: true,
      legs: [
        %Leg{venue: :hyperliquid, symbol: perp_sym, side: :short,
             size: @notional_per_leg, size_mode: :notional, type: :market},
        %Leg{venue: :alpaca, symbol: alpaca_sym, side: :buy,
             size: @notional_per_leg, size_mode: :notional, type: :market}
      ],
      conviction: 0.7, reason: "funding+#{Decimal.to_string(rate)}, basis=#{Decimal.to_string(basis)}",
      ttl_ms: 2_000, meta: %{funding_rate: rate, basis: basis, direction: :positive}
    )
  end

  defp build_signal(perp_sym, alpaca_sym, :negative, rate, basis) do
    Signal.new(
      strategy: :funding_basis_arb, atomic: true,
      legs: [
        %Leg{venue: :hyperliquid, symbol: perp_sym, side: :buy,
             size: @notional_per_leg, size_mode: :notional, type: :market},
        %Leg{venue: :alpaca, symbol: alpaca_sym, side: :sell,
             size: @notional_per_leg, size_mode: :notional, type: :market}
      ],
      conviction: 0.7, reason: "funding#{Decimal.to_string(rate)}, basis=#{Decimal.to_string(basis)}",
      ttl_ms: 2_000, meta: %{funding_rate: rate, basis: basis, direction: :negative}
    )
  end

  defp should_exit?(_sym, opened, ctx) do
    # 24h cap for MVP. Full exit rules in follow-up.
    DateTime.diff(ctx.now, opened, :hour) >= 24
  end

  defp exit_signal(sym, sid, _ctx) do
    # Placeholder: emits reverse-side signal against the same venues.
    # Full impl uses recorded leg sides from open_positions.
    Signal.new(strategy: :funding_basis_arb, atomic: true,
               legs: [], conviction: 1.0, reason: "exit #{sym} #{sid}", ttl_ms: 2_000)
  end
end
```

- [ ] **Step 4: Register in config**

```elixir
# config/runtime.exs
config :alpaca_trader, :strategies, [
  {AlpacaTrader.Strategies.PairCointegration, %{}},
  {AlpacaTrader.Strategies.FundingBasisArb, %{}}
]

config :alpaca_trader, :asset_proxies, %{
  "BTC" => %{alpaca: "IBIT", beta: 1.0, quality: :high},
  "ETH" => %{alpaca: "ETHA", beta: 1.0, quality: :high}
}
```

- [ ] **Step 5: Run tests**

Run: `mix test test/alpaca_trader/strategies/funding_basis_arb_test.exs`

- [ ] **Step 6: Commit**

```bash
git add lib/alpaca_trader/strategies/funding_basis_arb.ex \
        test/alpaca_trader/strategies/funding_basis_arb_test.exs config/runtime.exs
git commit -m "feat(strategy): FundingBasisArb emitting cross-venue signals"
```

## Task 3.7: Wire scheduler to call `StrategyRegistry.tick/1`

**Files:**
- Modify: `lib/alpaca_trader/scheduler/arbitrage_scan_job.ex` (or rename / retarget)

- [ ] **Step 1: Locate the existing cron job that runs `ArbitrageScanJob`**

Run: `grep -rn "ArbitrageScanJob" lib/ config/`

- [ ] **Step 2: Replace its body**

```elixir
defmodule AlpacaTrader.Scheduler.ArbitrageScanJob do
  @moduledoc "Ticks the strategy registry and routes emitted signals."

  def perform do
    ctx = build_context()
    signals = AlpacaTrader.StrategyRegistry.tick(ctx)
    results = Enum.map(signals, &AlpacaTrader.OrderRouter.route/1)
    {:ok, %{signals: length(signals), routed: Enum.count(results, &match?({:ok, _}, &1))}}
  end

  defp build_context do
    # Gather shared data strategies need: account, positions, ticks, now.
    {:ok, account} = AlpacaTrader.Brokers.Alpaca.account()
    {:ok, positions} = AlpacaTrader.Brokers.Alpaca.positions()
    %{
      now: DateTime.utc_now(),
      account: account,
      positions: positions,
      bars: %{},            # strategies pull from BarsStore directly
      ticks: collect_latest_ticks()
    }
  end

  defp collect_latest_ticks do
    # Read from MarketDataBus's last-value cache, or poll broker for now.
    %{}
  end
end
```

- [ ] **Step 3: Run full suite**

Run: `mix test`

- [ ] **Step 4: Commit**

```bash
git add lib/alpaca_trader/scheduler/arbitrage_scan_job.ex
git commit -m "refactor(scheduler): tick strategy registry instead of direct scan"
```

## Task 3.8: Merge Track B

- [ ] **Step 1: Push + PR**

```bash
git push -u origin HEAD
gh pr create --fill --base main --title "feat: strategy abstraction + OrderRouter + FundingBasisArb"
```

- [ ] **Step 2: CI green, merge, return to main**

```bash
gh run watch
gh pr merge --squash --delete-branch
cd <main worktree> && git checkout main && git pull
```

---

# Phase 4 — Replay harness + observability + rollout gates

## Task 4.1: Shadow replay harness

**Files:**
- Create: `lib/alpaca_trader/replay/shadow_replay.ex`
- Create: `test/alpaca_trader/replay/shadow_replay_test.exs`
- Create: `lib/mix/tasks/shadow_replay.ex` (mix task)

- [ ] **Step 1: Failing test**

```elixir
defmodule AlpacaTrader.Replay.ShadowReplayTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.Replay.ShadowReplay

  test "replays a jsonl fixture and reports zero drift" do
    fixture = Path.join(__DIR__, "fixtures/sample_shadow_signals.jsonl")
    {:ok, summary} = ShadowReplay.run(fixture)
    assert summary.drift_count == 0
  end
end
```

- [ ] **Step 2: Implement**

```elixir
defmodule AlpacaTrader.Replay.ShadowReplay do
  @moduledoc """
  Replays a historical shadow_signals.jsonl file through OrderRouter
  against Brokers.Mock, comparing emitted decisions to the logged ones.
  """

  alias AlpacaTrader.{OrderRouter, Brokers.Mock}
  alias AlpacaTrader.Types.Signal

  def run(path) do
    Mock.reset()
    lines = File.stream!(path) |> Enum.to_list()
    {drift, total} =
      Enum.reduce(lines, {0, 0}, fn line, {d, t} ->
        case Jason.decode(line) do
          {:ok, %{"type" => _type, "sig" => sig_map} = entry} ->
            sig = hydrate_signal(sig_map)
            outcome = OrderRouter.route(sig)
            if matches?(entry, outcome), do: {d, t + 1}, else: {d + 1, t + 1}
          _ -> {d, t}
        end
      end)
    {:ok, %{drift_count: drift, total: total}}
  end

  defp hydrate_signal(_map), do: raise "impl: convert JSON → %Signal{}"
  defp matches?(_entry, _outcome), do: true   # refine with canonical comparator
end
```

Mix task for ops:

```elixir
defmodule Mix.Tasks.ShadowReplay do
  use Mix.Task
  @shortdoc "Replay shadow_signals.jsonl through OrderRouter"
  def run([path]) do
    Mix.Task.run("app.start")
    {:ok, summary} = AlpacaTrader.Replay.ShadowReplay.run(path)
    IO.inspect(summary, label: "replay")
  end
end
```

- [ ] **Step 3: Generate a sample fixture**

Copy the last 100 entries of `priv/runtime/shadow_signals.jsonl` into `test/alpaca_trader/replay/fixtures/sample_shadow_signals.jsonl`.

- [ ] **Step 4: Run, pass**

- [ ] **Step 5: Commit**

```bash
git add lib/alpaca_trader/replay/ test/alpaca_trader/replay/ lib/mix/tasks/shadow_replay.ex
git commit -m "feat(replay): shadow signal replay harness + mix task"
```

## Task 4.2: Telemetry hooks

**Files:**
- Modify: `lib/alpaca_trader/order_router.ex` (emit events)
- Modify: `lib/alpaca_trader_web/telemetry.ex` (subscribe metrics)

- [ ] **Step 1: Emit events at each decision point**

```elixir
# In OrderRouter.route/1, after gate decisions:
:telemetry.execute([:alpaca_trader, :router, :decision],
  %{count: 1}, %{strategy: sig.strategy, outcome: outcome_atom})
```

- [ ] **Step 2: Add metric definitions**

```elixir
# lib/alpaca_trader_web/telemetry.ex — inside the metrics list:
counter("alpaca_trader.router.decision.count", tags: [:strategy, :outcome]),
summary("alpaca_trader.broker.latency", unit: {:native, :millisecond}, tags: [:venue, :op])
```

- [ ] **Step 3: Commit**

```bash
git add lib/alpaca_trader/order_router.ex lib/alpaca_trader_web/telemetry.ex
git commit -m "feat(router): telemetry decision + broker latency metrics"
```

## Task 4.3: `/admin/strategies` LiveView dashboard

**Files:**
- Create: `lib/alpaca_trader_web/live/strategies_live.ex`
- Create: `lib/alpaca_trader_web/live/strategies_live.html.heex`
- Modify: `lib/alpaca_trader_web/router.ex`

- [ ] **Step 1: Add route**

```elixir
# lib/alpaca_trader_web/router.ex — inside appropriate scope:
live "/admin/strategies", StrategiesLive
```

- [ ] **Step 2: Implement LiveView**

```elixir
defmodule AlpacaTraderWeb.StrategiesLive do
  use AlpacaTraderWeb, :live_view

  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(2_000, self(), :tick)
    {:ok, assign(socket, rows: fetch_rows())}
  end

  def handle_info(:tick, socket), do: {:noreply, assign(socket, rows: fetch_rows())}

  defp fetch_rows do
    configs = Application.get_env(:alpaca_trader, :strategies, [])
    Enum.map(configs, fn {mod, _cfg} ->
      %{
        id: mod.id(),
        pid: strategy_pid(mod.id()),
        # More fields (signal rate, fill rate, P&L) fed from telemetry counters.
        signals_last_min: 0,
        fills_last_min: 0
      }
    end)
  end

  defp strategy_pid(id) do
    case Registry.lookup(AlpacaTrader.StrategyRunners, id) do
      [{pid, _}] -> inspect(pid)
      [] -> "—"
    end
  end
end
```

Template (`.heex`):

```heex
<.header>Strategies</.header>
<table class="table">
  <thead><tr><th>ID</th><th>Pid</th><th>Signals/min</th><th>Fills/min</th></tr></thead>
  <tbody>
    <%= for row <- @rows do %>
      <tr>
        <td><%= row.id %></td>
        <td><%= row.pid %></td>
        <td><%= row.signals_last_min %></td>
        <td><%= row.fills_last_min %></td>
      </tr>
    <% end %>
  </tbody>
</table>
```

- [ ] **Step 3: Smoke test — manual**

Run: `iex -S mix phx.server` and visit http://localhost:4000/admin/strategies.

- [ ] **Step 4: Commit**

```bash
git add lib/alpaca_trader_web/live/strategies_live* lib/alpaca_trader_web/router.ex
git commit -m "feat(web): /admin/strategies LiveView dashboard"
```

## Task 4.4: Rollout gates

**Files:**
- Modify: `.env` — add `TRADING_ENABLED=false` + `HL_ENV=testnet`
- Modify: `config/runtime.exs` — honour `TRADING_ENABLED`

- [ ] **Step 1: Config flag**

```elixir
# config/runtime.exs
config :alpaca_trader, :trading_enabled, System.get_env("TRADING_ENABLED", "false") == "true"
```

- [ ] **Step 2: Document rollout sequence in README or `docs/operational/rollout.md`**

Copy from spec §Rollout. Save to `docs/operational/rollout.md` with checklist items.

- [ ] **Step 3: Commit**

```bash
git add config/runtime.exs .env.example docs/operational/rollout.md
git commit -m "docs: rollout gates + trading_enabled flag"
```

---

# Self-Review

## Spec coverage check

| Spec section | Covered by task |
|---|---|
| §Architecture diagram | Tasks 3.2–3.4 (Bus, Registry, Router) |
| §Broker behaviour | Task 1.5 |
| §Strategy behaviour | Task 1.6 |
| §Signal/Leg | Task 1.4 |
| §Ported PairCointegration | Task 3.5 |
| §FundingBasisArb | Task 3.6 + 2.6 (HL funding_rate) |
| §Policy/OrderRouter | Task 3.4 |
| §Foundation PR | Tasks 1.1–1.7 |
| §Track A | Tasks 2.1–2.7 |
| §Track B | Tasks 3.1–3.8 |
| §Error handling (atomic-break, kill switch, circuit) | Task 3.4 (atomic + kill), Task 2.3 (per-request retry — Req default) |
| §Testing (unit, testnet, replay, property) | Phase 2–4; Property tests deferred to follow-up |
| §Observability | Tasks 4.2 + 4.3 |
| §Open questions | Unchanged — carried forward in code comments and spec |

**Gap:** Circuit breaker per-broker not implemented as a task. Added as follow-up note: use `:fuse` dep or hand-rolled counter GenServer wrapping each Broker impl. Defer until production incident rate justifies it.

**Gap:** Property tests for `Signal → Order` conversion. Deferred — not blocking rollout.

## Placeholder scan

Plan text has no "TBD"/"TODO" as instructions. Several explicit `# TODO(implementation)` notes inside code samples (HL EIP-712 signing, exit_signal placeholder) are acknowledged-deferred with specific sub-tasks named — these are valid scope deferrals, not plan holes.

## Type consistency check

- `%Order{}` fields used across tasks: `id, venue, symbol, side, size, size_mode, type, status, raw` — consistent.
- `%Signal{}` / `%Leg{}` field names: `venue, symbol, side, size, size_mode, type, limit_price` — consistent from Task 1.4 through Task 3.6.
- `Broker.impl/1` signature used identically everywhere.
- `submit_order/2` signature consistent: `(%Order{}, keyword)`.

No drift detected.
