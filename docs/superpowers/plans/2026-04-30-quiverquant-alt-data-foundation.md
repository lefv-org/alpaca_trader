# QuiverQuant Alt-Data Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add five QuiverQuant feeds (Congress, Insider, GovContracts, Lobbying, WSB) as new providers under the existing `AltData` subsystem, writing normalized signals to `SignalStore` on per-feed poll cadences.

**Architecture:** Three-layer split inside `lib/alpaca_trader/alt_data/`. A single `Quiver.Client` handles HTTP (auth, retry, timeout) and is `Req.Test`-pluggable. A pure `Quiver.Parser` maps raw rows from each endpoint into `AltData.Signal` lists. Five thin GenServer providers (`Providers.Quiver*`) reuse the existing `AltData.Provider` `__using__` macro — each one wires Client + Parser, schedules its own polls, and writes to `SignalStore`. All five feeds default to disabled and are wired into `AltData.Supervisor` behind individual env flags. No engine or strategy behaviour changes.

**Tech Stack:** Elixir 1.16+, OTP 26+, Req 0.5 (HTTP + `Req.Test` plug), ExUnit, ETS (already used by `SignalStore`).

**Spec:** `docs/superpowers/specs/2026-04-30-quiverquant-alt-data-foundation-design.md`

---

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/alpaca_trader/alt_data/quiver/client.ex` | HTTP wrapper: auth header, base URL, retries, timeout, `Req.Test` plug injection |
| `lib/alpaca_trader/alt_data/quiver/parser.ex` | Pure functions, one per endpoint, mapping raw rows + `now` → `[AltData.Signal.t()]` |
| `lib/alpaca_trader/alt_data/providers/quiver_congress.ex` | Provider: poll + map for Congress feed |
| `lib/alpaca_trader/alt_data/providers/quiver_insider.ex` | Provider: poll + map for Insider feed |
| `lib/alpaca_trader/alt_data/providers/quiver_govcontracts.ex` | Provider: poll + map for Government Contracts feed |
| `lib/alpaca_trader/alt_data/providers/quiver_lobbying.ex` | Provider: poll + map for Lobbying feed |
| `lib/alpaca_trader/alt_data/providers/quiver_wsb.ex` | Provider: poll + map for WSB sentiment feed |
| `lib/alpaca_trader/alt_data/supervisor.ex` (modify) | Add five children gated on `_enabled` flags |
| `config/runtime.exs` (modify) | Add Quiver env-var block |
| `config/test.exs` (modify) | Register `:quiver_req_plug` for `Req.Test` |
| `test/alpaca_trader/alt_data/quiver/client_test.exs` | HTTP behaviour: auth, retry, timeout, errors |
| `test/alpaca_trader/alt_data/quiver/parser_test.exs` | Per-endpoint parser mapping (fixture-driven) |
| `test/alpaca_trader/alt_data/providers/quiver_*_test.exs` (×5) | Provider-level: writes to store, error path keeps store, disabled is inert |
| `test/alpaca_trader/alt_data/quiver_supervisor_test.exs` | Integration: full set boots, signals end up in `SignalStore` |
| `test/support/fixtures/quiver/{congress,insider,govcontracts,lobbying,wsb}.json` | Sanitized real-shape sample payloads |

Each parser/provider pair is its own task to keep changes self-contained.

---

## Task 1: HTTP Client + Test Wiring

**Files:**
- Create: `lib/alpaca_trader/alt_data/quiver/client.ex`
- Modify: `config/test.exs` (register `:quiver_req_plug`)
- Test: `test/alpaca_trader/alt_data/quiver/client_test.exs`

- [ ] **Step 1: Add Req.Test plug entry to config/test.exs**

Open `config/test.exs` and add the plug entry to the existing `:alpaca_trader` config block (next to `req_plug:`):

```elixir
config :alpaca_trader,
  req_plug: {Req.Test, AlpacaTrader.Alpaca.Client},
  quiver_req_plug: {Req.Test, AlpacaTrader.AltData.Quiver.Client},
  skip_startup_sync: true
```

- [ ] **Step 2: Write the failing client test**

Create `test/alpaca_trader/alt_data/quiver/client_test.exs`:

```elixir
defmodule AlpacaTrader.AltData.Quiver.ClientTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.AltData.Quiver.Client

  @plug AlpacaTrader.AltData.Quiver.Client

  setup do
    Application.put_env(:alpaca_trader, :quiverquant_api_key, "test-key")
    Application.put_env(:alpaca_trader, :quiver_base_url, "https://api.quiverquant.com/beta")
    Application.put_env(:alpaca_trader, :quiver_timeout_ms, 5_000)
    :ok
  end

  test "get/2 sends bearer auth and returns decoded body on 200" do
    Req.Test.stub(@plug, fn conn ->
      assert ["Bearer test-key"] = Plug.Conn.get_req_header(conn, "authorization")
      Req.Test.json(conn, [%{"Ticker" => "AAPL"}])
    end)

    assert {:ok, [%{"Ticker" => "AAPL"}]} = Client.get("/bulk/congresstrading", %{})
  end

  test "get/2 retries on 429 then succeeds" do
    counter = :counters.new(1, [:atomics])

    Req.Test.stub(@plug, fn conn ->
      n = :counters.add(counter, 1, 1) && :counters.get(counter, 1)

      if n < 3 do
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(429, ~s({"error":"rate limited"}))
      else
        Req.Test.json(conn, [%{"ok" => true}])
      end
    end)

    assert {:ok, [%{"ok" => true}]} = Client.get("/x", %{})
    assert :counters.get(counter, 1) == 3
  end

  test "get/2 returns error after exhausting retries on 5xx" do
    Req.Test.stub(@plug, fn conn ->
      Plug.Conn.send_resp(conn, 503, ~s({"error":"down"}))
    end)

    assert {:error, {:http_status, 503, _}} = Client.get("/x", %{})
  end

  test "get/2 returns :no_api_key when key missing" do
    Application.delete_env(:alpaca_trader, :quiverquant_api_key)
    assert {:error, :no_api_key} = Client.get("/x", %{})
  end

  test "get/2 surfaces 401 immediately as :unauthorized (no retry)" do
    counter = :counters.new(1, [:atomics])

    Req.Test.stub(@plug, fn conn ->
      :counters.add(counter, 1, 1)
      Plug.Conn.send_resp(conn, 401, ~s({"error":"unauthorized"}))
    end)

    assert {:error, :unauthorized} = Client.get("/x", %{})
    assert :counters.get(counter, 1) == 1
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/alpaca_trader/alt_data/quiver/client_test.exs`
Expected: COMPILE FAILURE — `AlpacaTrader.AltData.Quiver.Client.get/2` is undefined.

- [ ] **Step 4: Implement the client**

Create `lib/alpaca_trader/alt_data/quiver/client.ex`:

```elixir
defmodule AlpacaTrader.AltData.Quiver.Client do
  @moduledoc """
  Thin Req-based client for QuiverQuant beta API.

  Honors `:quiverquant_api_key`, `:quiver_base_url`, `:quiver_timeout_ms`
  application env. Test injection via `:quiver_req_plug`.
  """

  require Logger

  @max_attempts 3
  @retry_status_set MapSet.new([429, 500, 502, 503, 504])

  @spec get(String.t(), map() | keyword()) ::
          {:ok, list() | map()} | {:error, term()}
  def get(path, params \\ %{}) do
    case Application.get_env(:alpaca_trader, :quiverquant_api_key) do
      nil -> {:error, :no_api_key}
      "" -> {:error, :no_api_key}
      key -> do_get(path, params, key, 1)
    end
  end

  defp do_get(path, params, key, attempt) do
    case Req.get(req(key), url: path, params: normalize_params(params)) do
      {:ok, %{status: s, body: body}} when s in 200..299 ->
        {:ok, body}

      {:ok, %{status: 401, body: body}} ->
        {:error, :unauthorized}
        |> tap(fn _ ->
          Logger.error("[Quiver] 401 unauthorized: #{inspect(body) |> String.slice(0..120)}")
        end)

      {:ok, %{status: 403, body: body}} ->
        {:error, :forbidden}
        |> tap(fn _ ->
          Logger.error("[Quiver] 403 forbidden: #{inspect(body) |> String.slice(0..120)}")
        end)

      {:ok, %{status: status, body: body}} ->
        if attempt < @max_attempts and MapSet.member?(@retry_status_set, status) do
          Logger.warning("[Quiver] status=#{status} attempt=#{attempt}, retrying")
          backoff(attempt)
          do_get(path, params, key, attempt + 1)
        else
          {:error, {:http_status, status, body}}
        end

      {:error, reason} ->
        if attempt < @max_attempts do
          Logger.warning("[Quiver] transport error attempt=#{attempt}: #{inspect(reason)}")
          backoff(attempt)
          do_get(path, params, key, attempt + 1)
        else
          {:error, reason}
        end
    end
  end

  defp req(key) do
    base = Application.get_env(:alpaca_trader, :quiver_base_url, "https://api.quiverquant.com/beta")
    timeout = Application.get_env(:alpaca_trader, :quiver_timeout_ms, 15_000)

    opts = [
      base_url: base,
      headers: [
        {"authorization", "Bearer #{key}"},
        {"accept", "application/json"}
      ],
      receive_timeout: timeout,
      connect_options: [timeout: 5_000]
    ]

    case Application.get_env(:alpaca_trader, :quiver_req_plug) do
      nil -> Req.new(opts)
      plug -> Req.new(Keyword.put(opts, :plug, plug))
    end
  end

  defp normalize_params(params) when is_map(params), do: Map.to_list(params)
  defp normalize_params(params) when is_list(params), do: params

  defp backoff(attempt) do
    # 500ms, 1000ms, 2000ms; tests stub Process.sleep via short timeouts.
    Process.sleep(500 * round(:math.pow(2, attempt - 1)))
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/alpaca_trader/alt_data/quiver/client_test.exs`
Expected: 5 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add config/test.exs lib/alpaca_trader/alt_data/quiver/client.ex test/alpaca_trader/alt_data/quiver/client_test.exs
git commit -m "feat(alt_data): add QuiverQuant HTTP client with retry"
```

---

## Task 2: Parser Module Skeleton + Congress Feed

**Files:**
- Create: `lib/alpaca_trader/alt_data/quiver/parser.ex`
- Create: `test/support/fixtures/quiver/congress.json`
- Create: `test/alpaca_trader/alt_data/quiver/parser_test.exs`

- [ ] **Step 1: Create the Congress fixture**

Create `test/support/fixtures/quiver/congress.json`:

```json
[
  {"Representative":"Nancy Pelosi","Ticker":"NVDA","Transaction":"Purchase","Range":"$1,000,001 - $5,000,000","TransactionDate":"2026-04-22","ReportDate":"2026-04-25","House":"House"},
  {"Representative":"Nancy Pelosi","Ticker":"NVDA","Transaction":"Purchase","Range":"$500,001 - $1,000,000","TransactionDate":"2026-04-23","ReportDate":"2026-04-26","House":"House"},
  {"Representative":"Dan Crenshaw","Ticker":"NVDA","Transaction":"Purchase","Range":"$15,001 - $50,000","TransactionDate":"2026-04-21","ReportDate":"2026-04-24","House":"House"},
  {"Representative":"Tommy Tuberville","Ticker":"BA","Transaction":"Sale","Range":"$50,001 - $100,000","TransactionDate":"2026-04-20","ReportDate":"2026-04-23","House":"Senate"},
  {"Representative":"Mark Warner","Ticker":"AAPL","Transaction":"Purchase","Range":"$1,001 - $15,000","TransactionDate":"2026-03-01","ReportDate":"2026-03-04","House":"Senate"}
]
```

- [ ] **Step 2: Write the failing parser test**

Create `test/alpaca_trader/alt_data/quiver/parser_test.exs`:

```elixir
defmodule AlpacaTrader.AltData.Quiver.ParserTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.AltData.Quiver.Parser
  alias AlpacaTrader.AltData.Signal

  defp load_fixture(name) do
    Path.join([__DIR__, "..", "..", "..", "support", "fixtures", "quiver", "#{name}.json"])
    |> File.read!()
    |> Jason.decode!()
  end

  describe "parse_congress/3" do
    setup do
      now = ~U[2026-04-30 12:00:00Z]
      {:ok, rows: load_fixture("congress"), now: now}
    end

    test "groups by ticker within lookback window and emits one signal per group", %{rows: rows, now: now} do
      signals = Parser.parse_congress(rows, now, 14)

      tickers = Enum.map(signals, & hd(&1.affected_symbols)) |> Enum.sort()
      assert tickers == ["BA", "NVDA"]
      # AAPL filing is older than 14d lookback (~60d) and must be filtered out.
      refute Enum.any?(signals, fn s -> "AAPL" in s.affected_symbols end)
    end

    test "marks bullish when net Purchases > Sales", %{rows: rows, now: now} do
      [nvda] = Enum.filter(Parser.parse_congress(rows, now, 14), &("NVDA" in &1.affected_symbols))
      assert nvda.direction == :bullish
      assert nvda.signal_type == :congress_trade
      assert nvda.provider == :quiver_congress
      # Net = +3 (3 buys, 0 sells); strength = min(1.0, 3/5) = 0.6
      assert_in_delta nvda.strength, 0.6, 0.001
    end

    test "marks bearish when net Sales > Purchases", %{rows: rows, now: now} do
      [ba] = Enum.filter(Parser.parse_congress(rows, now, 14), &("BA" in &1.affected_symbols))
      assert ba.direction == :bearish
      assert_in_delta ba.strength, 0.2, 0.001
    end

    test "sets fetched_at = now and expires_at = now + lookback days", %{rows: rows, now: now} do
      [s | _] = Parser.parse_congress(rows, now, 14)
      assert DateTime.compare(s.fetched_at, now) == :eq
      assert DateTime.compare(s.expires_at, DateTime.add(now, 14 * 24 * 3600, :second)) == :eq
    end

    test "raw payload contains net_count and filings list", %{rows: rows, now: now} do
      [nvda] = Enum.filter(Parser.parse_congress(rows, now, 14), &("NVDA" in &1.affected_symbols))
      assert nvda.raw[:net_count] == 3
      assert is_list(nvda.raw[:filings])
      assert length(nvda.raw[:filings]) == 3
    end

    test "returns [] when input is empty or all rows are stale", %{now: now} do
      assert Parser.parse_congress([], now, 14) == []
      assert Parser.parse_congress([%{"Ticker" => "X", "Transaction" => "Purchase", "TransactionDate" => "2020-01-01"}], now, 14) == []
    end

    test "skips rows with missing ticker or unparseable date", %{now: now} do
      junk = [
        %{"Ticker" => nil, "Transaction" => "Purchase", "TransactionDate" => "2026-04-22"},
        %{"Ticker" => "X", "Transaction" => "Purchase", "TransactionDate" => "not-a-date"}
      ]
      assert Parser.parse_congress(junk, now, 14) == []
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/alpaca_trader/alt_data/quiver/parser_test.exs`
Expected: COMPILE FAILURE — `Parser.parse_congress/3` undefined.

- [ ] **Step 4: Implement Parser with Congress mapping**

Create `lib/alpaca_trader/alt_data/quiver/parser.ex`:

```elixir
defmodule AlpacaTrader.AltData.Quiver.Parser do
  @moduledoc """
  Pure parsers: raw QuiverQuant rows + `now` -> [AltData.Signal].
  One `parse_<feed>/N` per endpoint. No I/O, no application env reads.
  """

  alias AlpacaTrader.AltData.Signal

  @doc "Congress trades — `/bulk/congresstrading`."
  @spec parse_congress(list(map()), DateTime.t(), pos_integer()) :: [Signal.t()]
  def parse_congress(rows, now, lookback_days) when is_list(rows) do
    cutoff = DateTime.add(now, -lookback_days * 24 * 3600, :second)

    rows
    |> Enum.flat_map(&normalize_congress_row/1)
    |> Enum.filter(fn r -> DateTime.compare(r.txn_dt, cutoff) != :lt end)
    |> Enum.group_by(& &1.ticker)
    |> Enum.flat_map(fn {ticker, group} -> [build_congress_signal(ticker, group, now, lookback_days)] end)
  end

  defp normalize_congress_row(%{"Ticker" => t, "Transaction" => txn, "TransactionDate" => date_str} = row)
       when is_binary(t) and t != "" do
    case Date.from_iso8601(date_str) do
      {:ok, d} ->
        [%{
          ticker: String.upcase(t),
          txn_kind: classify_congress_txn(txn),
          txn_dt: DateTime.new!(d, ~T[00:00:00], "Etc/UTC"),
          range: row["Range"],
          rep: row["Representative"],
          house: row["House"]
        }]

      _ ->
        []
    end
  end

  defp normalize_congress_row(_), do: []

  defp classify_congress_txn("Purchase"), do: :buy
  defp classify_congress_txn("Sale" <> _), do: :sell
  defp classify_congress_txn(_), do: :other

  defp build_congress_signal(ticker, group, now, lookback_days) do
    buys = Enum.count(group, &(&1.txn_kind == :buy))
    sells = Enum.count(group, &(&1.txn_kind == :sell))
    net = buys - sells

    direction =
      cond do
        net > 0 -> :bullish
        net < 0 -> :bearish
        true -> :neutral
      end

    strength = min(1.0, abs(net) / 5.0)

    %Signal{
      provider: :quiver_congress,
      signal_type: :congress_trade,
      direction: direction,
      strength: strength,
      affected_symbols: [ticker],
      reason: "Congressional net=#{net} (#{buys} buys / #{sells} sells) over #{lookback_days}d",
      fetched_at: now,
      expires_at: DateTime.add(now, lookback_days * 24 * 3600, :second),
      raw: %{
        net_count: net,
        filings: Enum.map(group, &Map.take(&1, [:rep, :txn_kind, :txn_dt, :range, :house]))
      }
    }
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/alpaca_trader/alt_data/quiver/parser_test.exs`
Expected: 7 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/alpaca_trader/alt_data/quiver/parser.ex test/alpaca_trader/alt_data/quiver/parser_test.exs test/support/fixtures/quiver/congress.json
git commit -m "feat(alt_data): QuiverQuant Parser + Congress feed mapping"
```

---

## Task 3: QuiverCongress Provider

**Files:**
- Create: `lib/alpaca_trader/alt_data/providers/quiver_congress.ex`
- Test: `test/alpaca_trader/alt_data/providers/quiver_congress_test.exs`

- [ ] **Step 1: Write the failing provider test**

Create `test/alpaca_trader/alt_data/providers/quiver_congress_test.exs`:

```elixir
defmodule AlpacaTrader.AltData.Providers.QuiverCongressTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.AltData.Providers.QuiverCongress
  alias AlpacaTrader.AltData.SignalStore

  @plug AlpacaTrader.AltData.Quiver.Client

  setup do
    Application.put_env(:alpaca_trader, :quiverquant_api_key, "test-key")
    Application.put_env(:alpaca_trader, :quiver_base_url, "https://api.quiverquant.com/beta")
    Application.put_env(:alpaca_trader, :quiver_congress_enabled, true)
    Application.put_env(:alpaca_trader, :quiver_congress_poll_s, 1800)
    Application.put_env(:alpaca_trader, :quiver_congress_lookback_d, 14)

    case Process.whereis(SignalStore) do
      nil -> {:ok, _} = SignalStore.start_link([])
      _ -> :ok
    end

    :ets.delete_all_objects(:alt_data_signals)
    :ok
  end

  test "fetch/0 calls bulk/congresstrading and returns parsed signals" do
    today = Date.utc_today() |> Date.to_iso8601()

    Req.Test.stub(@plug, fn conn ->
      assert conn.request_path == "/bulk/congresstrading"
      Req.Test.json(conn, [
        %{"Ticker" => "AAPL", "Transaction" => "Purchase", "TransactionDate" => today, "Representative" => "X", "Range" => "$1-$15K"}
      ])
    end)

    assert {:ok, [signal]} = QuiverCongress.fetch()
    assert signal.provider == :quiver_congress
    assert signal.affected_symbols == ["AAPL"]
  end

  test "fetch/0 returns {:ok, []} when api key is missing (inert)" do
    Application.delete_env(:alpaca_trader, :quiverquant_api_key)
    assert {:ok, []} = QuiverCongress.fetch()
  end

  test "fetch/0 surfaces client errors" do
    Req.Test.stub(@plug, fn conn ->
      Plug.Conn.send_resp(conn, 503, ~s({"err":"down"}))
    end)

    assert {:error, _} = QuiverCongress.fetch()
  end

  test "provider_id/0 and poll_interval_ms/0 honor config" do
    assert QuiverCongress.provider_id() == :quiver_congress
    assert QuiverCongress.poll_interval_ms() == 1_800_000
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/alpaca_trader/alt_data/providers/quiver_congress_test.exs`
Expected: COMPILE FAILURE — module undefined.

- [ ] **Step 3: Implement the provider**

Create `lib/alpaca_trader/alt_data/providers/quiver_congress.ex`:

```elixir
defmodule AlpacaTrader.AltData.Providers.QuiverCongress do
  @moduledoc """
  Congressional trade filings (STOCK Act). Polls
  `/bulk/congresstrading` and emits one signal per ticker per
  lookback window.
  """

  use AlpacaTrader.AltData.Provider

  alias AlpacaTrader.AltData.Quiver.{Client, Parser}

  @impl true
  def provider_id, do: :quiver_congress

  @impl true
  def poll_interval_ms do
    :timer.seconds(Application.get_env(:alpaca_trader, :quiver_congress_poll_s, 1800))
  end

  @impl true
  def fetch do
    case Application.get_env(:alpaca_trader, :quiverquant_api_key) do
      nil -> {:ok, []}
      "" -> {:ok, []}
      _ ->
        lookback = Application.get_env(:alpaca_trader, :quiver_congress_lookback_d, 14)

        case Client.get("/bulk/congresstrading") do
          {:ok, rows} when is_list(rows) ->
            {:ok, Parser.parse_congress(rows, DateTime.utc_now(), lookback)}

          {:ok, _other} ->
            {:error, :unexpected_payload}

          {:error, _} = err ->
            err
        end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/alpaca_trader/alt_data/providers/quiver_congress_test.exs`
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/alpaca_trader/alt_data/providers/quiver_congress.ex test/alpaca_trader/alt_data/providers/quiver_congress_test.exs
git commit -m "feat(alt_data): QuiverCongress provider"
```

---

## Task 4: Insider Feed (Parser + Provider)

**Files:**
- Create: `test/support/fixtures/quiver/insider.json`
- Modify: `lib/alpaca_trader/alt_data/quiver/parser.ex` (add `parse_insider/3`)
- Modify: `test/alpaca_trader/alt_data/quiver/parser_test.exs` (add `describe "parse_insider/3"`)
- Create: `lib/alpaca_trader/alt_data/providers/quiver_insider.ex`
- Create: `test/alpaca_trader/alt_data/providers/quiver_insider_test.exs`

- [ ] **Step 1: Create the Insider fixture**

Create `test/support/fixtures/quiver/insider.json`:

```json
[
  {"Ticker":"AAPL","Name":"Tim Cook","Code":"P","Shares":"5000","PricePerShare":"180.00","Date":"2026-04-22"},
  {"Ticker":"AAPL","Name":"Luca Maestri","Code":"P","Shares":"3000","PricePerShare":"180.00","Date":"2026-04-23"},
  {"Ticker":"BA","Name":"David Calhoun","Code":"S","Shares":"10000","PricePerShare":"200.00","Date":"2026-04-20"},
  {"Ticker":"OLD","Name":"Anyone","Code":"P","Shares":"100","PricePerShare":"10.00","Date":"2025-01-01"}
]
```

- [ ] **Step 2: Add insider tests to parser_test.exs**

Append a new `describe` block to `test/alpaca_trader/alt_data/quiver/parser_test.exs` (before the final `end`):

```elixir
  describe "parse_insider/3" do
    setup do
      now = ~U[2026-04-30 12:00:00Z]
      {:ok, rows: load_fixture("insider"), now: now}
    end

    test "skips rows outside lookback window", %{rows: rows, now: now} do
      signals = Parser.parse_insider(rows, now, 30)
      tickers = Enum.flat_map(signals, & &1.affected_symbols) |> Enum.sort()
      assert tickers == ["AAPL", "BA"]
    end

    test "tags cluster when 2+ insiders buy same ticker", %{rows: rows, now: now} do
      [aapl] = Enum.filter(Parser.parse_insider(rows, now, 30), &("AAPL" in &1.affected_symbols))
      assert aapl.direction == :bullish
      assert aapl.signal_type == :insider_buy_cluster
      # Net = 5000*180 + 3000*180 = 1_440_000; cluster threshold 500_000
      # strength = min(1.0, 1_440_000 / 500_000) = 1.0
      assert_in_delta aapl.strength, 1.0, 0.001
    end

    test "single insider sale uses :insider_trade and 1M threshold", %{now: now} do
      rows = [
        %{"Ticker" => "X", "Name" => "P1", "Code" => "S", "Shares" => "1000", "PricePerShare" => "300.00", "Date" => "2026-04-25"}
      ]

      [s] = Parser.parse_insider(rows, now, 30)
      assert s.direction == :bearish
      assert s.signal_type == :insider_trade
      # Net = -300_000; threshold 1_000_000; strength = 0.3
      assert_in_delta s.strength, 0.3, 0.001
    end

    test "skips rows with non-P/S codes", %{now: now} do
      rows = [
        %{"Ticker" => "X", "Name" => "P1", "Code" => "G", "Shares" => "100", "PricePerShare" => "10", "Date" => "2026-04-25"}
      ]

      assert Parser.parse_insider(rows, now, 30) == []
    end
  end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mix test test/alpaca_trader/alt_data/quiver/parser_test.exs`
Expected: COMPILE FAILURE — `Parser.parse_insider/3` undefined.

- [ ] **Step 4: Add `parse_insider/3` to Parser**

Append to `lib/alpaca_trader/alt_data/quiver/parser.ex` (before the final `end`):

```elixir
  @doc "Insider Form-4 filings — `/beta/live/insiders`."
  @spec parse_insider(list(map()), DateTime.t(), pos_integer()) :: [Signal.t()]
  def parse_insider(rows, now, lookback_days) when is_list(rows) do
    cutoff = DateTime.add(now, -lookback_days * 24 * 3600, :second)

    rows
    |> Enum.flat_map(&normalize_insider_row/1)
    |> Enum.filter(fn r -> DateTime.compare(r.txn_dt, cutoff) != :lt end)
    |> Enum.group_by(& &1.ticker)
    |> Enum.map(fn {ticker, group} -> build_insider_signal(ticker, group, now, lookback_days) end)
  end

  defp normalize_insider_row(%{"Ticker" => t, "Code" => code, "Shares" => sh, "PricePerShare" => pps, "Date" => date_str} = row)
       when is_binary(t) and t != "" and code in ["P", "S"] do
    with {:ok, d} <- Date.from_iso8601(date_str),
         {shares, _} <- Float.parse(to_string(sh)),
         {price, _} <- Float.parse(to_string(pps)) do
      [%{
        ticker: String.upcase(t),
        code: code,
        dollars: shares * price * if(code == "P", do: 1.0, else: -1.0),
        insider: row["Name"],
        txn_dt: DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
      }]
    else
      _ -> []
    end
  end

  defp normalize_insider_row(_), do: []

  defp build_insider_signal(ticker, group, now, lookback_days) do
    net_dollars = group |> Enum.map(& &1.dollars) |> Enum.sum()
    direction = if net_dollars >= 0, do: :bullish, else: :bearish

    {cluster?, signal_type} =
      case classify_insider_cluster(group, direction) do
        :cluster_buy -> {true, :insider_buy_cluster}
        :cluster_sell -> {true, :insider_sell_cluster}
        :single -> {false, :insider_trade}
      end

    threshold = if cluster?, do: 500_000.0, else: 1_000_000.0
    strength = min(1.0, abs(net_dollars) / threshold)

    %Signal{
      provider: :quiver_insider,
      signal_type: signal_type,
      direction: direction,
      strength: strength,
      affected_symbols: [ticker],
      reason: "Insider net=$#{trunc(net_dollars)} over #{lookback_days}d (#{length(group)} filings)",
      fetched_at: now,
      expires_at: DateTime.add(now, lookback_days * 24 * 3600, :second),
      raw: %{net_dollars: net_dollars, filings: length(group), cluster: cluster?}
    }
  end

  defp classify_insider_cluster(group, direction) do
    same_dir =
      Enum.filter(group, fn r ->
        (direction == :bullish and r.code == "P") or (direction == :bearish and r.code == "S")
      end)

    distinct_insiders =
      same_dir
      |> Enum.map(& &1.insider)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> length()

    cond do
      distinct_insiders >= 2 and direction == :bullish -> :cluster_buy
      distinct_insiders >= 2 and direction == :bearish -> :cluster_sell
      true -> :single
    end
  end
```

- [ ] **Step 5: Run parser tests to verify they pass**

Run: `mix test test/alpaca_trader/alt_data/quiver/parser_test.exs`
Expected: 11 tests, 0 failures.

- [ ] **Step 6: Write the failing provider test**

Create `test/alpaca_trader/alt_data/providers/quiver_insider_test.exs`:

```elixir
defmodule AlpacaTrader.AltData.Providers.QuiverInsiderTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.AltData.Providers.QuiverInsider
  alias AlpacaTrader.AltData.SignalStore

  @plug AlpacaTrader.AltData.Quiver.Client

  setup do
    Application.put_env(:alpaca_trader, :quiverquant_api_key, "test-key")
    Application.put_env(:alpaca_trader, :quiver_insider_enabled, true)
    Application.put_env(:alpaca_trader, :quiver_insider_poll_s, 900)
    Application.put_env(:alpaca_trader, :quiver_insider_lookback_d, 30)

    case Process.whereis(SignalStore) do
      nil -> {:ok, _} = SignalStore.start_link([])
      _ -> :ok
    end

    :ets.delete_all_objects(:alt_data_signals)
    :ok
  end

  test "fetch/0 hits /beta/live/insiders" do
    Req.Test.stub(@plug, fn conn ->
      assert conn.request_path == "/beta/live/insiders"
      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = QuiverInsider.fetch()
  end

  test "fetch/0 inert when key missing" do
    Application.delete_env(:alpaca_trader, :quiverquant_api_key)
    assert {:ok, []} = QuiverInsider.fetch()
  end

  test "provider_id/0 and poll_interval_ms/0" do
    assert QuiverInsider.provider_id() == :quiver_insider
    assert QuiverInsider.poll_interval_ms() == 900_000
  end
end
```

- [ ] **Step 7: Run test to verify it fails**

Run: `mix test test/alpaca_trader/alt_data/providers/quiver_insider_test.exs`
Expected: COMPILE FAILURE — module undefined.

- [ ] **Step 8: Implement the provider**

Create `lib/alpaca_trader/alt_data/providers/quiver_insider.ex`:

```elixir
defmodule AlpacaTrader.AltData.Providers.QuiverInsider do
  @moduledoc "Form-4 corporate insider filings."

  use AlpacaTrader.AltData.Provider

  alias AlpacaTrader.AltData.Quiver.{Client, Parser}

  @impl true
  def provider_id, do: :quiver_insider

  @impl true
  def poll_interval_ms do
    :timer.seconds(Application.get_env(:alpaca_trader, :quiver_insider_poll_s, 900))
  end

  @impl true
  def fetch do
    case Application.get_env(:alpaca_trader, :quiverquant_api_key) do
      nil -> {:ok, []}
      "" -> {:ok, []}
      _ ->
        lookback = Application.get_env(:alpaca_trader, :quiver_insider_lookback_d, 30)

        case Client.get("/beta/live/insiders") do
          {:ok, rows} when is_list(rows) ->
            {:ok, Parser.parse_insider(rows, DateTime.utc_now(), lookback)}

          {:ok, _other} ->
            {:error, :unexpected_payload}

          {:error, _} = err ->
            err
        end
    end
  end
end
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `mix test test/alpaca_trader/alt_data/providers/quiver_insider_test.exs`
Expected: 3 tests, 0 failures.

- [ ] **Step 10: Commit**

```bash
git add lib/alpaca_trader/alt_data/quiver/parser.ex lib/alpaca_trader/alt_data/providers/quiver_insider.ex test/alpaca_trader/alt_data/quiver/parser_test.exs test/alpaca_trader/alt_data/providers/quiver_insider_test.exs test/support/fixtures/quiver/insider.json
git commit -m "feat(alt_data): QuiverInsider feed (parser + provider)"
```

---

## Task 5: GovContracts Feed (Parser + Provider)

**Files:**
- Create: `test/support/fixtures/quiver/govcontracts.json`
- Modify: `lib/alpaca_trader/alt_data/quiver/parser.ex` (add `parse_govcontracts/3`)
- Modify: `test/alpaca_trader/alt_data/quiver/parser_test.exs`
- Create: `lib/alpaca_trader/alt_data/providers/quiver_govcontracts.ex`
- Create: `test/alpaca_trader/alt_data/providers/quiver_govcontracts_test.exs`

- [ ] **Step 1: Create the GovContracts fixture**

Create `test/support/fixtures/quiver/govcontracts.json`:

```json
[
  {"Ticker":"LMT","Amount":"45000000","Description":"Aircraft parts","Date":"2026-04-25","Agency":"DOD"},
  {"Ticker":"LMT","Amount":"60000000","Description":"Maintenance","Date":"2026-04-22","Agency":"DOD"},
  {"Ticker":"BA","Amount":"-5000000","Description":"Cancellation","Date":"2026-04-21","Agency":"DOD"},
  {"Ticker":"BA","Amount":"20000000","Description":"Engine","Date":"2026-04-20","Agency":"DOD"},
  {"Ticker":"OLD","Amount":"1000000","Description":"X","Date":"2025-01-01","Agency":"DOD"}
]
```

- [ ] **Step 2: Add govcontracts tests to parser_test.exs**

Append to `test/alpaca_trader/alt_data/quiver/parser_test.exs` (before final `end`):

```elixir
  describe "parse_govcontracts/3" do
    setup do
      now = ~U[2026-04-30 12:00:00Z]
      {:ok, rows: load_fixture("govcontracts"), now: now}
    end

    test "filters stale rows and cancellations", %{rows: rows, now: now} do
      signals = Parser.parse_govcontracts(rows, now, 30)
      tickers = Enum.flat_map(signals, & &1.affected_symbols) |> Enum.sort()
      assert tickers == ["BA", "LMT"]
    end

    test "always bullish on award totals", %{rows: rows, now: now} do
      [lmt] = Enum.filter(Parser.parse_govcontracts(rows, now, 30), &("LMT" in &1.affected_symbols))
      assert lmt.direction == :bullish
      assert lmt.signal_type == :gov_contract_award
      # 45M + 60M = 105M; cap at 100M; strength clipped to 1.0
      assert_in_delta lmt.strength, 1.0, 0.001
    end

    test "BA cancellation is excluded; only the 20M award counts", %{rows: rows, now: now} do
      [ba] = Enum.filter(Parser.parse_govcontracts(rows, now, 30), &("BA" in &1.affected_symbols))
      assert ba.raw[:total_amount] == 20_000_000
      assert_in_delta ba.strength, 0.2, 0.001
    end
  end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mix test test/alpaca_trader/alt_data/quiver/parser_test.exs`
Expected: `parse_govcontracts/3` undefined.

- [ ] **Step 4: Add `parse_govcontracts/3` to Parser**

Append to `lib/alpaca_trader/alt_data/quiver/parser.ex`:

```elixir
  @doc "Federal contract awards — `/beta/live/govcontractsall`."
  @spec parse_govcontracts(list(map()), DateTime.t(), pos_integer()) :: [Signal.t()]
  def parse_govcontracts(rows, now, lookback_days) when is_list(rows) do
    cutoff = DateTime.add(now, -lookback_days * 24 * 3600, :second)

    rows
    |> Enum.flat_map(&normalize_contract_row/1)
    |> Enum.filter(fn r -> DateTime.compare(r.dt, cutoff) != :lt and r.amount > 0 end)
    |> Enum.group_by(& &1.ticker)
    |> Enum.map(fn {ticker, group} -> build_contract_signal(ticker, group, now, lookback_days) end)
  end

  defp normalize_contract_row(%{"Ticker" => t, "Amount" => amt, "Date" => date_str} = row)
       when is_binary(t) and t != "" do
    with {:ok, d} <- Date.from_iso8601(date_str),
         {amount, _} <- Float.parse(to_string(amt)) do
      [%{
        ticker: String.upcase(t),
        amount: amount,
        agency: row["Agency"],
        description: row["Description"],
        dt: DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
      }]
    else
      _ -> []
    end
  end

  defp normalize_contract_row(_), do: []

  defp build_contract_signal(ticker, group, now, lookback_days) do
    total = group |> Enum.map(& &1.amount) |> Enum.sum() |> trunc()
    strength = min(1.0, total / 100_000_000)

    %Signal{
      provider: :quiver_govcontracts,
      signal_type: :gov_contract_award,
      direction: :bullish,
      strength: strength,
      affected_symbols: [ticker],
      reason: "$#{total} in federal contracts over #{lookback_days}d (#{length(group)} awards)",
      fetched_at: now,
      expires_at: DateTime.add(now, lookback_days * 24 * 3600, :second),
      raw: %{
        total_amount: total,
        award_count: length(group),
        agencies: group |> Enum.map(& &1.agency) |> Enum.uniq()
      }
    }
  end
```

- [ ] **Step 5: Run parser tests**

Run: `mix test test/alpaca_trader/alt_data/quiver/parser_test.exs`
Expected: 14 tests, 0 failures.

- [ ] **Step 6: Write the failing provider test**

Create `test/alpaca_trader/alt_data/providers/quiver_govcontracts_test.exs`:

```elixir
defmodule AlpacaTrader.AltData.Providers.QuiverGovContractsTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.AltData.Providers.QuiverGovContracts
  alias AlpacaTrader.AltData.SignalStore

  @plug AlpacaTrader.AltData.Quiver.Client

  setup do
    Application.put_env(:alpaca_trader, :quiverquant_api_key, "test-key")
    Application.put_env(:alpaca_trader, :quiver_govcontracts_enabled, true)
    Application.put_env(:alpaca_trader, :quiver_govcontracts_poll_s, 10800)
    Application.put_env(:alpaca_trader, :quiver_govcontracts_lookback_d, 30)

    case Process.whereis(SignalStore) do
      nil -> {:ok, _} = SignalStore.start_link([])
      _ -> :ok
    end

    :ets.delete_all_objects(:alt_data_signals)
    :ok
  end

  test "fetch/0 hits /beta/live/govcontractsall" do
    Req.Test.stub(@plug, fn conn ->
      assert conn.request_path == "/beta/live/govcontractsall"
      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = QuiverGovContracts.fetch()
  end

  test "fetch/0 inert when key missing" do
    Application.delete_env(:alpaca_trader, :quiverquant_api_key)
    assert {:ok, []} = QuiverGovContracts.fetch()
  end

  test "provider_id/0 and poll_interval_ms/0" do
    assert QuiverGovContracts.provider_id() == :quiver_govcontracts
    assert QuiverGovContracts.poll_interval_ms() == 10_800_000
  end
end
```

- [ ] **Step 7: Implement the provider**

Create `lib/alpaca_trader/alt_data/providers/quiver_govcontracts.ex`:

```elixir
defmodule AlpacaTrader.AltData.Providers.QuiverGovContracts do
  @moduledoc "Federal contract awards aggregated per ticker."

  use AlpacaTrader.AltData.Provider

  alias AlpacaTrader.AltData.Quiver.{Client, Parser}

  @impl true
  def provider_id, do: :quiver_govcontracts

  @impl true
  def poll_interval_ms do
    :timer.seconds(Application.get_env(:alpaca_trader, :quiver_govcontracts_poll_s, 10_800))
  end

  @impl true
  def fetch do
    case Application.get_env(:alpaca_trader, :quiverquant_api_key) do
      nil -> {:ok, []}
      "" -> {:ok, []}
      _ ->
        lookback = Application.get_env(:alpaca_trader, :quiver_govcontracts_lookback_d, 30)

        case Client.get("/beta/live/govcontractsall") do
          {:ok, rows} when is_list(rows) ->
            {:ok, Parser.parse_govcontracts(rows, DateTime.utc_now(), lookback)}

          {:ok, _other} ->
            {:error, :unexpected_payload}

          {:error, _} = err ->
            err
        end
    end
  end
end
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `mix test test/alpaca_trader/alt_data/providers/quiver_govcontracts_test.exs`
Expected: 3 tests, 0 failures.

- [ ] **Step 9: Commit**

```bash
git add lib/alpaca_trader/alt_data/quiver/parser.ex lib/alpaca_trader/alt_data/providers/quiver_govcontracts.ex test/alpaca_trader/alt_data/quiver/parser_test.exs test/alpaca_trader/alt_data/providers/quiver_govcontracts_test.exs test/support/fixtures/quiver/govcontracts.json
git commit -m "feat(alt_data): QuiverGovContracts feed (parser + provider)"
```

---

## Task 6: Lobbying Feed (Parser + Provider)

**Files:**
- Create: `test/support/fixtures/quiver/lobbying.json`
- Modify: `lib/alpaca_trader/alt_data/quiver/parser.ex`
- Modify: `test/alpaca_trader/alt_data/quiver/parser_test.exs`
- Create: `lib/alpaca_trader/alt_data/providers/quiver_lobbying.ex`
- Create: `test/alpaca_trader/alt_data/providers/quiver_lobbying_test.exs`

- [ ] **Step 1: Create the Lobbying fixture**

Create `test/support/fixtures/quiver/lobbying.json`:

```json
[
  {"Ticker":"GOOGL","Client":"Google LLC","Amount":"3500000","Year":2026,"Quarter":1},
  {"Ticker":"GOOGL","Client":"Google LLC","Amount":"2000000","Year":2025,"Quarter":1},
  {"Ticker":"NEWCO","Client":"NewCo","Amount":"1500000","Year":2026,"Quarter":1}
]
```

- [ ] **Step 2: Add lobbying tests to parser_test.exs**

Append to `parser_test.exs`:

```elixir
  describe "parse_lobbying/2" do
    setup do
      now = ~U[2026-04-30 12:00:00Z]
      {:ok, rows: load_fixture("lobbying"), now: now}
    end

    test "computes YoY delta strength when prior year exists", %{rows: rows, now: now} do
      [googl] = Enum.filter(Parser.parse_lobbying(rows, now), &("GOOGL" in &1.affected_symbols))
      assert googl.direction == :neutral
      assert googl.signal_type == :lobbying_spike
      # |3.5M - 2M| / max(1, 2M) = 0.75
      assert_in_delta googl.strength, 0.75, 0.001
    end

    test "strength = 0.0 when prior year missing", %{rows: rows, now: now} do
      [newco] = Enum.filter(Parser.parse_lobbying(rows, now), &("NEWCO" in &1.affected_symbols))
      assert newco.strength == 0.0
    end

    test "expires_at = now + 90d", %{rows: rows, now: now} do
      [s | _] = Parser.parse_lobbying(rows, now)
      assert DateTime.compare(s.expires_at, DateTime.add(now, 90 * 24 * 3600, :second)) == :eq
    end
  end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mix test test/alpaca_trader/alt_data/quiver/parser_test.exs`
Expected: `parse_lobbying/2` undefined.

- [ ] **Step 4: Add `parse_lobbying/2` to Parser**

Append to `parser.ex`:

```elixir
  @doc "Lobbying disclosures — `/beta/live/lobbying`. Latest disclosed quarter, with prior-year YoY delta."
  @spec parse_lobbying(list(map()), DateTime.t()) :: [Signal.t()]
  def parse_lobbying(rows, now) when is_list(rows) do
    rows
    |> Enum.flat_map(&normalize_lobbying_row/1)
    |> Enum.group_by(& &1.ticker)
    |> Enum.map(fn {ticker, group} -> build_lobbying_signal(ticker, group, now) end)
  end

  defp normalize_lobbying_row(%{"Ticker" => t, "Amount" => amt, "Year" => yr, "Quarter" => q})
       when is_binary(t) and t != "" do
    with {amount, _} <- Float.parse(to_string(amt)),
         year when is_integer(year) <- yr,
         quarter when is_integer(quarter) <- q do
      [%{ticker: String.upcase(t), amount: amount, year: year, quarter: quarter}]
    else
      _ -> []
    end
  end

  defp normalize_lobbying_row(_), do: []

  defp build_lobbying_signal(ticker, group, now) do
    {latest_year, latest_quarter} =
      group |> Enum.map(&{&1.year, &1.quarter}) |> Enum.max(fn a, b -> a >= b end, fn -> {0, 0} end)

    current = group |> Enum.filter(&(&1.year == latest_year and &1.quarter == latest_quarter)) |> Enum.map(& &1.amount) |> Enum.sum()
    prior = group |> Enum.filter(&(&1.year == latest_year - 1 and &1.quarter == latest_quarter)) |> Enum.map(& &1.amount) |> Enum.sum()

    strength =
      if prior > 0 do
        min(1.0, abs(current - prior) / prior)
      else
        0.0
      end

    %Signal{
      provider: :quiver_lobbying,
      signal_type: :lobbying_spike,
      direction: :neutral,
      strength: strength,
      affected_symbols: [ticker],
      reason: "Lobbying $#{trunc(current)} (Q#{latest_quarter} #{latest_year}) vs $#{trunc(prior)} prior year",
      fetched_at: now,
      expires_at: DateTime.add(now, 90 * 24 * 3600, :second),
      raw: %{current: current, prior_year: prior, year: latest_year, quarter: latest_quarter}
    }
  end
```

- [ ] **Step 5: Run parser tests**

Run: `mix test test/alpaca_trader/alt_data/quiver/parser_test.exs`
Expected: 17 tests, 0 failures.

- [ ] **Step 6: Write the failing provider test**

Create `test/alpaca_trader/alt_data/providers/quiver_lobbying_test.exs`:

```elixir
defmodule AlpacaTrader.AltData.Providers.QuiverLobbyingTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.AltData.Providers.QuiverLobbying
  alias AlpacaTrader.AltData.SignalStore

  @plug AlpacaTrader.AltData.Quiver.Client

  setup do
    Application.put_env(:alpaca_trader, :quiverquant_api_key, "test-key")
    Application.put_env(:alpaca_trader, :quiver_lobbying_enabled, true)
    Application.put_env(:alpaca_trader, :quiver_lobbying_poll_s, 43_200)

    case Process.whereis(SignalStore) do
      nil -> {:ok, _} = SignalStore.start_link([])
      _ -> :ok
    end

    :ets.delete_all_objects(:alt_data_signals)
    :ok
  end

  test "fetch/0 hits /beta/live/lobbying" do
    Req.Test.stub(@plug, fn conn ->
      assert conn.request_path == "/beta/live/lobbying"
      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = QuiverLobbying.fetch()
  end

  test "fetch/0 inert when key missing" do
    Application.delete_env(:alpaca_trader, :quiverquant_api_key)
    assert {:ok, []} = QuiverLobbying.fetch()
  end

  test "provider_id/0 and poll_interval_ms/0" do
    assert QuiverLobbying.provider_id() == :quiver_lobbying
    assert QuiverLobbying.poll_interval_ms() == 43_200_000
  end
end
```

- [ ] **Step 7: Implement the provider**

Create `lib/alpaca_trader/alt_data/providers/quiver_lobbying.ex`:

```elixir
defmodule AlpacaTrader.AltData.Providers.QuiverLobbying do
  @moduledoc "Federal lobbying disclosures."

  use AlpacaTrader.AltData.Provider

  alias AlpacaTrader.AltData.Quiver.{Client, Parser}

  @impl true
  def provider_id, do: :quiver_lobbying

  @impl true
  def poll_interval_ms do
    :timer.seconds(Application.get_env(:alpaca_trader, :quiver_lobbying_poll_s, 43_200))
  end

  @impl true
  def fetch do
    case Application.get_env(:alpaca_trader, :quiverquant_api_key) do
      nil -> {:ok, []}
      "" -> {:ok, []}
      _ ->
        case Client.get("/beta/live/lobbying") do
          {:ok, rows} when is_list(rows) ->
            {:ok, Parser.parse_lobbying(rows, DateTime.utc_now())}

          {:ok, _other} ->
            {:error, :unexpected_payload}

          {:error, _} = err ->
            err
        end
    end
  end
end
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `mix test test/alpaca_trader/alt_data/providers/quiver_lobbying_test.exs`
Expected: 3 tests, 0 failures.

- [ ] **Step 9: Commit**

```bash
git add lib/alpaca_trader/alt_data/quiver/parser.ex lib/alpaca_trader/alt_data/providers/quiver_lobbying.ex test/alpaca_trader/alt_data/quiver/parser_test.exs test/alpaca_trader/alt_data/providers/quiver_lobbying_test.exs test/support/fixtures/quiver/lobbying.json
git commit -m "feat(alt_data): QuiverLobbying feed (parser + provider)"
```

---

## Task 7: WSB Feed (Parser + Provider)

**Files:**
- Create: `test/support/fixtures/quiver/wsb.json`
- Modify: `lib/alpaca_trader/alt_data/quiver/parser.ex`
- Modify: `test/alpaca_trader/alt_data/quiver/parser_test.exs`
- Create: `lib/alpaca_trader/alt_data/providers/quiver_wsb.ex`
- Create: `test/alpaca_trader/alt_data/providers/quiver_wsb_test.exs`

- [ ] **Step 1: Create the WSB fixture**

Create `test/support/fixtures/quiver/wsb.json`:

```json
[
  {"Ticker":"GME","Mentions":650,"PreviousMentions":300,"Sentiment":0.78,"Date":"2026-04-30"},
  {"Ticker":"AMC","Mentions":120,"PreviousMentions":140,"Sentiment":0.30,"Date":"2026-04-30"},
  {"Ticker":"NVDA","Mentions":400,"PreviousMentions":250,"Sentiment":0.50,"Date":"2026-04-30"},
  {"Ticker":"TSLA","Mentions":80,"PreviousMentions":250,"Sentiment":0.20,"Date":"2026-04-30"}
]
```

- [ ] **Step 2: Add WSB tests to parser_test.exs**

Append to `parser_test.exs`:

```elixir
  describe "parse_wsb/2" do
    setup do
      now = ~U[2026-04-30 12:00:00Z]
      {:ok, rows: load_fixture("wsb"), now: now}
    end

    test "bullish when sentiment > 0.6 AND mentions rising", %{rows: rows, now: now} do
      [gme] = Enum.filter(Parser.parse_wsb(rows, now), &("GME" in &1.affected_symbols))
      assert gme.direction == :bullish
      assert gme.signal_type == :wsb_sentiment
      # 650 / 500 capped at 1.0
      assert_in_delta gme.strength, 1.0, 0.001
    end

    test "neutral when sentiment in middle band even with rising mentions", %{rows: rows, now: now} do
      [nvda] = Enum.filter(Parser.parse_wsb(rows, now), &("NVDA" in &1.affected_symbols))
      assert nvda.direction == :neutral
    end

    test "bearish requires sentiment < 0.4 AND mentions rising", %{rows: rows, now: now} do
      # AMC: sentiment 0.30 but mentions DROPPED -> :neutral
      [amc] = Enum.filter(Parser.parse_wsb(rows, now), &("AMC" in &1.affected_symbols))
      assert amc.direction == :neutral

      # TSLA: sentiment 0.20 AND mentions dropped -> :neutral
      [tsla] = Enum.filter(Parser.parse_wsb(rows, now), &("TSLA" in &1.affected_symbols))
      assert tsla.direction == :neutral

      # synthetic bearish: low sentiment + rising mentions
      bear_row = [%{"Ticker" => "X", "Mentions" => 300, "PreviousMentions" => 100, "Sentiment" => 0.15, "Date" => "2026-04-30"}]
      [x] = Parser.parse_wsb(bear_row, now)
      assert x.direction == :bearish
    end

    test "expires_at = now + 24h", %{rows: rows, now: now} do
      [s | _] = Parser.parse_wsb(rows, now)
      assert DateTime.compare(s.expires_at, DateTime.add(now, 24 * 3600, :second)) == :eq
    end
  end
```

- [ ] **Step 3: Run parser tests to verify failure**

Run: `mix test test/alpaca_trader/alt_data/quiver/parser_test.exs`
Expected: `parse_wsb/2` undefined.

- [ ] **Step 4: Add `parse_wsb/2` to Parser**

Append to `parser.ex`:

```elixir
  @doc "WallStreetBets sentiment — `/beta/live/wallstreetbets`."
  @spec parse_wsb(list(map()), DateTime.t()) :: [Signal.t()]
  def parse_wsb(rows, now) when is_list(rows) do
    rows
    |> Enum.flat_map(&normalize_wsb_row/1)
    |> Enum.map(&build_wsb_signal(&1, now))
  end

  defp normalize_wsb_row(%{"Ticker" => t, "Mentions" => m, "PreviousMentions" => prev, "Sentiment" => s})
       when is_binary(t) and t != "" do
    with {mentions, _} <- safe_to_float(m),
         {prev_mentions, _} <- safe_to_float(prev),
         {sentiment, _} <- safe_to_float(s) do
      [%{ticker: String.upcase(t), mentions: mentions, prev: prev_mentions, sentiment: sentiment}]
    else
      _ -> []
    end
  end

  defp normalize_wsb_row(_), do: []

  defp safe_to_float(n) when is_number(n), do: {n / 1, ""}
  defp safe_to_float(s) when is_binary(s), do: Float.parse(s)
  defp safe_to_float(_), do: :error

  defp build_wsb_signal(row, now) do
    rising? = row.mentions > row.prev

    direction =
      cond do
        row.sentiment > 0.6 and rising? -> :bullish
        row.sentiment < 0.4 and rising? -> :bearish
        true -> :neutral
      end

    strength = min(1.0, row.mentions / 500.0)

    %Signal{
      provider: :quiver_wsb,
      signal_type: :wsb_sentiment,
      direction: direction,
      strength: strength,
      affected_symbols: [row.ticker],
      reason: "WSB sentiment=#{row.sentiment} mentions=#{trunc(row.mentions)} (prev=#{trunc(row.prev)})",
      fetched_at: now,
      expires_at: DateTime.add(now, 24 * 3600, :second),
      raw: %{mentions: row.mentions, prev_mentions: row.prev, sentiment: row.sentiment}
    }
  end
```

- [ ] **Step 5: Run parser tests**

Run: `mix test test/alpaca_trader/alt_data/quiver/parser_test.exs`
Expected: 21 tests, 0 failures.

- [ ] **Step 6: Write the failing provider test**

Create `test/alpaca_trader/alt_data/providers/quiver_wsb_test.exs`:

```elixir
defmodule AlpacaTrader.AltData.Providers.QuiverWsbTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.AltData.Providers.QuiverWsb
  alias AlpacaTrader.AltData.SignalStore

  @plug AlpacaTrader.AltData.Quiver.Client

  setup do
    Application.put_env(:alpaca_trader, :quiverquant_api_key, "test-key")
    Application.put_env(:alpaca_trader, :quiver_wsb_enabled, true)
    Application.put_env(:alpaca_trader, :quiver_wsb_poll_s, 450)

    case Process.whereis(SignalStore) do
      nil -> {:ok, _} = SignalStore.start_link([])
      _ -> :ok
    end

    :ets.delete_all_objects(:alt_data_signals)
    :ok
  end

  test "fetch/0 hits /beta/live/wallstreetbets" do
    Req.Test.stub(@plug, fn conn ->
      assert conn.request_path == "/beta/live/wallstreetbets"
      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = QuiverWsb.fetch()
  end

  test "fetch/0 inert when key missing" do
    Application.delete_env(:alpaca_trader, :quiverquant_api_key)
    assert {:ok, []} = QuiverWsb.fetch()
  end

  test "provider_id/0 and poll_interval_ms/0" do
    assert QuiverWsb.provider_id() == :quiver_wsb
    assert QuiverWsb.poll_interval_ms() == 450_000
  end
end
```

- [ ] **Step 7: Implement the provider**

Create `lib/alpaca_trader/alt_data/providers/quiver_wsb.ex`:

```elixir
defmodule AlpacaTrader.AltData.Providers.QuiverWsb do
  @moduledoc "WallStreetBets mention + sentiment feed."

  use AlpacaTrader.AltData.Provider

  alias AlpacaTrader.AltData.Quiver.{Client, Parser}

  @impl true
  def provider_id, do: :quiver_wsb

  @impl true
  def poll_interval_ms do
    :timer.seconds(Application.get_env(:alpaca_trader, :quiver_wsb_poll_s, 450))
  end

  @impl true
  def fetch do
    case Application.get_env(:alpaca_trader, :quiverquant_api_key) do
      nil -> {:ok, []}
      "" -> {:ok, []}
      _ ->
        case Client.get("/beta/live/wallstreetbets") do
          {:ok, rows} when is_list(rows) ->
            {:ok, Parser.parse_wsb(rows, DateTime.utc_now())}

          {:ok, _other} ->
            {:error, :unexpected_payload}

          {:error, _} = err ->
            err
        end
    end
  end
end
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `mix test test/alpaca_trader/alt_data/providers/quiver_wsb_test.exs`
Expected: 3 tests, 0 failures.

- [ ] **Step 9: Commit**

```bash
git add lib/alpaca_trader/alt_data/quiver/parser.ex lib/alpaca_trader/alt_data/providers/quiver_wsb.ex test/alpaca_trader/alt_data/quiver/parser_test.exs test/alpaca_trader/alt_data/providers/quiver_wsb_test.exs test/support/fixtures/quiver/wsb.json
git commit -m "feat(alt_data): QuiverWsb feed (parser + provider)"
```

---

## Task 8: Runtime Config + Supervisor Wiring + Init Jitter

**Files:**
- Modify: `config/runtime.exs`
- Modify: `lib/alpaca_trader/alt_data/supervisor.ex`
- Modify (each provider): override `init/1` to apply startup jitter
- Create: `test/alpaca_trader/alt_data/quiver_supervisor_test.exs`

- [ ] **Step 1: Add Quiver block to `config/runtime.exs`**

In the `if config_env() != :test do` block of `config/runtime.exs`, append the following lines just before the block's closing `end` (next to the existing `alt_data_*` keys):

```elixir
    quiverquant_api_key: System.get_env("QUIVERQUANT_API_KEY"),
    quiver_base_url: System.get_env("QUIVER_BASE_URL", "https://api.quiverquant.com/beta"),
    quiver_timeout_ms: String.to_integer(System.get_env("QUIVER_TIMEOUT_MS", "15000")),
    quiver_congress_enabled: System.get_env("QUIVER_CONGRESS_ENABLED", "false") == "true",
    quiver_insider_enabled: System.get_env("QUIVER_INSIDER_ENABLED", "false") == "true",
    quiver_govcontracts_enabled: System.get_env("QUIVER_GOVCONTRACTS_ENABLED", "false") == "true",
    quiver_lobbying_enabled: System.get_env("QUIVER_LOBBYING_ENABLED", "false") == "true",
    quiver_wsb_enabled: System.get_env("QUIVER_WSB_ENABLED", "false") == "true",
    quiver_congress_poll_s: String.to_integer(System.get_env("QUIVER_CONGRESS_POLL_S", "1800")),
    quiver_insider_poll_s: String.to_integer(System.get_env("QUIVER_INSIDER_POLL_S", "900")),
    quiver_govcontracts_poll_s: String.to_integer(System.get_env("QUIVER_GOVCONTRACTS_POLL_S", "10800")),
    quiver_lobbying_poll_s: String.to_integer(System.get_env("QUIVER_LOBBYING_POLL_S", "43200")),
    quiver_wsb_poll_s: String.to_integer(System.get_env("QUIVER_WSB_POLL_S", "450")),
    quiver_congress_lookback_d: String.to_integer(System.get_env("QUIVER_CONGRESS_LOOKBACK_D", "14")),
    quiver_insider_lookback_d: String.to_integer(System.get_env("QUIVER_INSIDER_LOOKBACK_D", "30")),
    quiver_govcontracts_lookback_d: String.to_integer(System.get_env("QUIVER_GOVCONTRACTS_LOOKBACK_D", "30")),
```

(The list is added to the same `config :alpaca_trader, ...` keyword so each entry needs a leading comma if the existing list ends without one — verify against the immediately preceding key.)

- [ ] **Step 2: Add the five Quiver children to `AltData.Supervisor`**

Edit `lib/alpaca_trader/alt_data/supervisor.ex`. Replace the body of `enabled_providers/0` so the keyword list reads:

```elixir
  defp enabled_providers do
    alias AlpacaTrader.AltData.Providers

    [
      {Providers.Fred, Application.get_env(:alpaca_trader, :alt_data_fred_enabled, true)},
      {Providers.OpenMeteo,
       Application.get_env(:alpaca_trader, :alt_data_open_meteo_enabled, true)},
      {Providers.OpenSky, Application.get_env(:alpaca_trader, :alt_data_opensky_enabled, true)},
      {Providers.NasaFirms,
       Application.get_env(:alpaca_trader, :alt_data_nasa_firms_enabled, false)},
      {Providers.Nws, Application.get_env(:alpaca_trader, :alt_data_nws_enabled, true)},
      {Providers.Finnhub, Application.get_env(:alpaca_trader, :alt_data_finnhub_enabled, false)},
      {Providers.QuiverCongress,
       quiver_enabled?(:quiver_congress_enabled)},
      {Providers.QuiverInsider,
       quiver_enabled?(:quiver_insider_enabled)},
      {Providers.QuiverGovContracts,
       quiver_enabled?(:quiver_govcontracts_enabled)},
      {Providers.QuiverLobbying,
       quiver_enabled?(:quiver_lobbying_enabled)},
      {Providers.QuiverWsb,
       quiver_enabled?(:quiver_wsb_enabled)}
    ]
    |> Enum.filter(fn {_mod, enabled} -> enabled end)
    |> Enum.map(fn {mod, _} -> mod end)
  end

  defp quiver_enabled?(flag) do
    Application.get_env(:alpaca_trader, flag, false) and
      not is_nil(Application.get_env(:alpaca_trader, :quiverquant_api_key)) and
      Application.get_env(:alpaca_trader, :quiverquant_api_key) != ""
  end
```

- [ ] **Step 3: Override `init/1` in each Quiver provider for startup jitter**

For each of the five files:

- `lib/alpaca_trader/alt_data/providers/quiver_congress.ex`
- `lib/alpaca_trader/alt_data/providers/quiver_insider.ex`
- `lib/alpaca_trader/alt_data/providers/quiver_govcontracts.ex`
- `lib/alpaca_trader/alt_data/providers/quiver_lobbying.ex`
- `lib/alpaca_trader/alt_data/providers/quiver_wsb.ex`

Append the following inside the module (before its final `end`):

```elixir
  @impl GenServer
  def init(_) do
    jitter_ms = :rand.uniform(max(1, div(poll_interval_ms(), 4)))
    Process.send_after(self(), :poll, jitter_ms)
    {:ok, %{consecutive_errors: 0}}
  end
```

This replaces the macro-injected default `init/1` (which uses `send(self(), :poll)` for an immediate first poll) so the five providers desynchronize on supervisor startup.

- [ ] **Step 4: Write the supervisor integration test**

Create `test/alpaca_trader/alt_data/quiver_supervisor_test.exs`:

```elixir
defmodule AlpacaTrader.AltData.QuiverSupervisorTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.AltData.SignalStore

  @plug AlpacaTrader.AltData.Quiver.Client

  setup do
    Application.put_env(:alpaca_trader, :quiverquant_api_key, "test-key")
    Application.put_env(:alpaca_trader, :quiver_base_url, "https://api.quiverquant.com/beta")

    # Disable non-quiver providers so we don't trigger network from them.
    for k <- [
          :alt_data_fred_enabled,
          :alt_data_open_meteo_enabled,
          :alt_data_opensky_enabled,
          :alt_data_nasa_firms_enabled,
          :alt_data_nws_enabled,
          :alt_data_finnhub_enabled
        ] do
      Application.put_env(:alpaca_trader, k, false)
    end

    for k <- [
          :quiver_congress_enabled,
          :quiver_insider_enabled,
          :quiver_govcontracts_enabled,
          :quiver_lobbying_enabled,
          :quiver_wsb_enabled
        ] do
      Application.put_env(:alpaca_trader, k, true)
    end

    Application.put_env(:alpaca_trader, :quiver_congress_poll_s, 60)
    Application.put_env(:alpaca_trader, :quiver_insider_poll_s, 60)
    Application.put_env(:alpaca_trader, :quiver_govcontracts_poll_s, 60)
    Application.put_env(:alpaca_trader, :quiver_lobbying_poll_s, 60)
    Application.put_env(:alpaca_trader, :quiver_wsb_poll_s, 60)
    Application.put_env(:alpaca_trader, :quiver_congress_lookback_d, 14)
    Application.put_env(:alpaca_trader, :quiver_insider_lookback_d, 30)
    Application.put_env(:alpaca_trader, :quiver_govcontracts_lookback_d, 30)

    case Process.whereis(SignalStore) do
      nil -> {:ok, _} = SignalStore.start_link([])
      _ -> :ok
    end

    :ets.delete_all_objects(:alt_data_signals)

    today = Date.utc_today() |> Date.to_iso8601()

    Req.Test.stub(@plug, fn conn ->
      body =
        case conn.request_path do
          "/bulk/congresstrading" ->
            [%{"Ticker" => "AAPL", "Transaction" => "Purchase", "TransactionDate" => today, "Range" => "$1-$15K", "Representative" => "X"}]

          "/beta/live/insiders" ->
            [%{"Ticker" => "AAPL", "Name" => "X", "Code" => "P", "Shares" => "100", "PricePerShare" => "100", "Date" => today}]

          "/beta/live/govcontractsall" ->
            [%{"Ticker" => "LMT", "Amount" => "10000000", "Description" => "x", "Date" => today, "Agency" => "DOD"}]

          "/beta/live/lobbying" ->
            [%{"Ticker" => "GOOGL", "Client" => "G", "Amount" => "1000000", "Year" => Date.utc_today().year, "Quarter" => 1}]

          "/beta/live/wallstreetbets" ->
            [%{"Ticker" => "GME", "Mentions" => 700, "PreviousMentions" => 300, "Sentiment" => 0.8, "Date" => today}]

          _ ->
            []
        end

      Req.Test.json(conn, body)
    end)

    :ok
  end

  test "all five providers boot, poll, and write to SignalStore" do
    {:ok, sup} = AlpacaTrader.AltData.Supervisor.start_link([])
    on_exit(fn -> Process.exit(sup, :normal) end)

    # Force an immediate poll on each by sending :poll.
    for mod <- [
          AlpacaTrader.AltData.Providers.QuiverCongress,
          AlpacaTrader.AltData.Providers.QuiverInsider,
          AlpacaTrader.AltData.Providers.QuiverGovContracts,
          AlpacaTrader.AltData.Providers.QuiverLobbying,
          AlpacaTrader.AltData.Providers.QuiverWsb
        ] do
      send(Process.whereis(mod), :poll)
    end

    # Allow async polls to complete.
    Process.sleep(500)

    providers =
      SignalStore.status()
      |> Enum.map(fn {p, _, _} -> p end)
      |> Enum.sort()

    assert :quiver_congress in providers
    assert :quiver_insider in providers
    assert :quiver_govcontracts in providers
    assert :quiver_lobbying in providers
    assert :quiver_wsb in providers
    assert length(SignalStore.all_active()) >= 5
  end
end
```

- [ ] **Step 5: Run integration test to verify it passes**

Run: `mix test test/alpaca_trader/alt_data/quiver_supervisor_test.exs`
Expected: 1 test, 0 failures.

- [ ] **Step 6: Run the full alt_data test suite**

Run: `mix test test/alpaca_trader/alt_data/`
Expected: All Quiver tests pass; previously existing alt_data tests (if any) remain green.

- [ ] **Step 7: Commit**

```bash
git add config/runtime.exs lib/alpaca_trader/alt_data/supervisor.ex lib/alpaca_trader/alt_data/providers/quiver_*.ex test/alpaca_trader/alt_data/quiver_supervisor_test.exs
git commit -m "feat(alt_data): wire Quiver providers into supervisor with jitter"
```

---

## Task 9: Final Verification & PR

**Files:** none (validation only)

- [ ] **Step 1: Run full test suite**

Run: `mix test`
Expected: All tests pass. No new warnings.

- [ ] **Step 2: Check for compiler warnings**

Run: `mix compile --warnings-as-errors`
Expected: Compiles clean.

- [ ] **Step 3: Run Credo if configured**

Run: `mix credo --strict 2>/dev/null || echo "credo not configured"`
Expected: No new issues introduced. (If Credo is not in this project, skip.)

- [ ] **Step 4: Sanity-check supervisor with all-disabled (default)**

Run: `MIX_ENV=test mix run -e "Application.ensure_all_started(:alpaca_trader); :ok = AlpacaTrader.AltData.Supervisor |> Process.whereis() |> is_pid() |> if(do: :ok, else: :no_supervisor) |> IO.inspect()"`
Expected: prints `:ok`. With Quiver flags off (default), no Quiver children booted; existing providers unchanged.

- [ ] **Step 5: Push branch and open PR**

```bash
git push -u origin HEAD
gh pr create --fill --base main --title "feat(alt_data): QuiverQuant foundation (5 feeds)"
```

- [ ] **Step 6: Wait for CI to pass**

Run: `gh run watch`
Expected: All checks green.

- [ ] **Step 7: Merge**

```bash
gh pr merge --squash --delete-branch
git checkout main
git pull origin main
```

---

## Caveat: Speculative Field Names

QuiverQuant's `/beta` JSON field names in this plan (e.g. `Mentions`,
`PreviousMentions`, `Range`, `Code`, `Quarter`) are taken from public
documentation and the `politician-trading-tracker` repo's reference
implementation. The live API may differ. After Task 8, run a manual smoke
against the real key (one feed at a time, e.g. `QUIVER_CONGRESS_ENABLED=true`
+ all others off) and inspect `Logger.info` output. If parser yields zero
signals against non-empty payloads, the field names need adjusting in
`Parser.normalize_<feed>_row/1` plus the corresponding fixture. This is the
single most likely real-world friction point.

## Acceptance Criteria

Mirror of spec section. Verify before declaring sub-project done:

1. With all five `_ENABLED=true` and a valid key, `mix test` passes including the supervisor integration test.
2. With `_ENABLED=false` (default), zero new processes start; existing tests remain green; no behaviour change to engine or strategies.
3. With invalid key, providers log permission denied each retry, then back off via the shared macro's exponential schedule (capped at 30 min). Other alt-data providers remain healthy. *(Hand-verified: set `QUIVERQUANT_API_KEY=bad-key` + one feed enabled and start app; observe 401 log on each scheduled poll, store stays empty for that provider.)*
4. `SignalStore.status/0` reflects the five new providers when enabled, with non-zero signal counts after first poll.
5. No new compiler warnings; no Credo regressions.
