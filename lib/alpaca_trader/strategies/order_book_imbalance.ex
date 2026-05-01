defmodule AlpacaTrader.Strategies.OrderBookImbalance do
  @moduledoc """
  Order-book imbalance strategy — ported from Alpaca's own open-source HFT
  example (github.com/alpacahq/example-hftish, 852 ★).

  ## Core idea

  When two conditions align simultaneously on a 1-penny spread stock:

    1. **Level change** — both bid AND ask moved by exactly $0.01 (a clean,
       single-penny step, not a gap caused by news).
    2. **Queue imbalance** — the size on one side overwhelms the other
       (`bid_size / ask_size > ratio` → buy pressure,
        `ask_size / bid_size > ratio` → sell pressure).

  …the market microstructure literature suggests prices are likely to tick
  in the direction of the larger queue.  We take a small, fast position and
  exit on the next level change.

  ## Resolution vs. the original

  The original Python bot runs on a WebSocket quote stream (millisecond
  latency).  This Elixir port polls `GET /v2/stocks/quotes/latest` on every
  StrategyScanJob tick (~1 minute cadence).  The same logic applies; only the
  resolution differs.  Upgrading to WebSocket streaming via `stream_ticks/2`
  in the Alpaca broker would make this genuinely sub-second.

  ## Configuration (all optional, env-overridable)

    * `:symbols`          — list of equity symbols to watch (default: OBI_SYMBOLS env)
    * `:imbalance_ratio`  — minimum size ratio to trigger (default: OBI_IMBALANCE_RATIO, 1.8)
    * `:max_qty`          — maximum shares per signal leg (default: OBI_MAX_QTY, 100)

  ## Long-only mode

  When `LONG_ONLY_MODE=true` (the default), sell/short signals are suppressed.
  """

  @behaviour AlpacaTrader.Strategy

  require Logger

  alias AlpacaTrader.Types.{Signal, Leg, FeedSpec}
  alias AlpacaTrader.Alpaca.Client

  # Minimum notional conviction — keeps the LLM gate happy at default 0.5 threshold.
  @conviction 0.72

  # Default symbol list if OBI_SYMBOLS env is absent.
  @default_symbols ~w[SPY QQQ AAPL MSFT TSLA NVDA AMZN META]

  # ── Strategy callbacks ────────────────────────────────────────────────────────

  @impl true
  def id, do: :order_book_imbalance

  @impl true
  def required_feeds do
    [%FeedSpec{venue: :alpaca, symbols: :whitelist, cadence: :tick}]
  end

  @impl true
  def init(config) do
    symbols = resolve_symbols(config)
    ratio = resolve_ratio(config)
    max_qty = resolve_max_qty(config)

    state = %{
      symbols: symbols,
      imbalance_ratio: ratio,
      max_qty: max_qty,
      # prev quote per symbol: %{"AAPL" => %{bid: f, ask: f, bid_size: n, ask_size: n}}
      prev_quotes: %{},
      # whether we already traded on this level per symbol
      traded_this_level: MapSet.new()
    }

    Logger.info(
      "[OBI] init symbols=#{inspect(symbols)} ratio=#{ratio} max_qty=#{max_qty}"
    )

    {:ok, state}
  end

  @impl true
  def scan(state, _ctx) do
    case Client.latest_stock_quotes_with_sizes(state.symbols) do
      {:ok, quotes} ->
        {signals, new_state} = evaluate_quotes(quotes, state)
        {:ok, signals, new_state}

      {:error, reason} ->
        Logger.warning("[OBI] quote fetch failed: #{inspect(reason)}")
        {:ok, [], state}
    end
  end

  @impl true
  def exits(state, _ctx), do: {:ok, [], state}

  @impl true
  def on_fill(state, _fill), do: {:ok, state}

  # ── Core logic ────────────────────────────────────────────────────────────────

  defp evaluate_quotes(quotes, state) do
    long_only = Application.get_env(:alpaca_trader, :long_only_mode, true)

    Enum.reduce(quotes, {[], state}, fn {symbol, quote}, {signals_acc, st} ->
      prev = Map.get(st.prev_quotes, symbol)
      already_traded = MapSet.member?(st.traded_this_level, symbol)

      {new_signals, new_st} =
        process_quote(symbol, quote, prev, already_traded, st, long_only)

      {signals_acc ++ new_signals, new_st}
    end)
  end

  # First time we see this symbol — just record the quote, no signal yet.
  defp process_quote(symbol, quote, nil, _already_traded, state, _long_only) do
    new_state = %{state | prev_quotes: Map.put(state.prev_quotes, symbol, quote)}
    {[], new_state}
  end

  defp process_quote(symbol, quote, prev, _already_traded, state, long_only)
       when is_map(prev) do
    # Alpaca's /v2/stocks/quotes/latest returns string-keyed maps
    # (%{"bp" => bid, "ap" => ask, "bs" => bid_size, "as" => ask_size}).
    # Earlier code accessed atom keys (quote.bid) which raised KeyError
    # on every scan, crashing the runner; the supervisor respawned it
    # but each in-flight registry call hit :noproc and waited the full
    # 25 s timeout. Extracting both shapes here makes the strategy
    # tolerant of either source.
    case {extract_quote(quote), extract_quote(prev)} do
      {{:ok, bid, ask, bid_size, ask_size}, {:ok, prev_bid, prev_ask, _, _}}
      when bid > 0.0 and ask > 0.0 and prev_bid > 0.0 and prev_ask > 0.0 ->
        process_quote_with_values(
          symbol,
          quote,
          state,
          long_only,
          bid,
          ask,
          bid_size,
          ask_size,
          prev_bid,
          prev_ask
        )

      # Zero-priced quotes happen when the market for the symbol is
      # closed (after-hours equity, missing crypto book). Skip — without
      # this guard OBI emits a limit order with limit_price=0.0 which
      # Alpaca rejects with \"limit price must be > 0\".
      _ ->
        {[], state}
    end
  end

  defp process_quote_with_values(
         symbol,
         quote,
         state,
         long_only,
         bid,
         ask,
         bid_size,
         ask_size,
         prev_bid,
         prev_ask
       ) do
    bid_size = max(bid_size, 1)
    ask_size = max(ask_size, 1)

    # Detect a clean 1-penny level change on BOTH sides simultaneously.
    spread = Float.round(ask - bid, 4)
    bid_moved = bid != prev_bid
    ask_moved = ask != prev_ask
    penny_spread = abs(spread - 0.01) < 0.001

    is_level_change = bid_moved and ask_moved and penny_spread

    {signals, new_traded} =
      cond do
        # New level — reset THIS symbol's traded flag, then check imbalance.
        # We delete only `symbol` from the set (preserving other symbols' state).
        is_level_change ->
          base = MapSet.delete(state.traded_this_level, symbol)
          sig = check_imbalance(symbol, bid, ask, bid_size, ask_size, state, long_only)
          traded = if sig != nil, do: MapSet.put(base, symbol), else: base
          {List.wrap(sig), traded}

        # Same level, haven't traded this symbol yet — check imbalance.
        not MapSet.member?(state.traded_this_level, symbol) ->
          sig = check_imbalance(symbol, bid, ask, bid_size, ask_size, state, long_only)
          traded = if sig != nil, do: MapSet.put(state.traded_this_level, symbol), else: state.traded_this_level
          {List.wrap(sig), traded}

        # Already traded this symbol on the current level — do nothing.
        true ->
          {[], state.traded_this_level}
      end

    new_state = %{
      state
      | prev_quotes: Map.put(state.prev_quotes, symbol, quote),
        traded_this_level: new_traded
    }

    {signals, new_state}
  end

  # Tolerant quote extractor: accepts Alpaca's string-keyed shape
  # (%{"bp" => bid, "ap" => ask, "bs" => bid_size, "as" => ask_size}) AND
  # any older atom-keyed shape we may have stored in prev_quotes from a
  # previous boot. Returns {:ok, bid, ask, bid_size, ask_size} or :error.
  defp extract_quote(%{"bp" => bp, "ap" => ap, "bs" => bs, "as" => as})
       when is_number(bp) and is_number(ap),
       do: {:ok, bp * 1.0, ap * 1.0, num(bs), num(as)}

  defp extract_quote(%{bid: bid, ask: ask, bid_size: bs, ask_size: as})
       when is_number(bid) and is_number(ask),
       do: {:ok, bid * 1.0, ask * 1.0, num(bs), num(as)}

  defp extract_quote(_), do: :error

  defp num(n) when is_number(n), do: n
  defp num(_), do: 1

  defp check_imbalance(symbol, bid, ask, bid_size, ask_size, state, long_only) do
    ratio = state.imbalance_ratio
    max_qty = state.max_qty

    cond do
      # Heavy bid side → buy pressure → buy at ask (aggressive taker)
      bid_size / ask_size > ratio ->
        Signal.new(
          strategy: id(),
          conviction: @conviction,
          reason: "OBI buy: bid_size=#{bid_size} ask_size=#{ask_size} ratio=#{Float.round(bid_size / ask_size, 2)}",
          ttl_ms: 90_000,
          legs: [
            %Leg{
              venue: :alpaca,
              symbol: symbol,
              side: :buy,
              size: max_qty,
              size_mode: :qty,
              type: :limit,
              limit_price: Decimal.from_float(Float.round(ask, 4))
            }
          ]
        )

      # Heavy ask side → sell pressure → sell at bid (only if short selling allowed)
      not long_only and ask_size / bid_size > ratio ->
        Signal.new(
          strategy: id(),
          conviction: @conviction,
          reason: "OBI sell: ask_size=#{ask_size} bid_size=#{bid_size} ratio=#{Float.round(ask_size / bid_size, 2)}",
          ttl_ms: 90_000,
          legs: [
            %Leg{
              venue: :alpaca,
              symbol: symbol,
              side: :sell,
              size: max_qty,
              size_mode: :qty,
              type: :limit,
              limit_price: Decimal.from_float(Float.round(bid, 4))
            }
          ]
        )

      true ->
        nil
    end
  end

  # ── Config helpers ────────────────────────────────────────────────────────────

  defp resolve_symbols(%{symbols: syms}) when is_list(syms) and syms != [], do: syms

  defp resolve_symbols(_config) do
    case System.get_env("OBI_SYMBOLS") do
      nil -> @default_symbols
      csv -> csv |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end
  end

  defp resolve_ratio(%{imbalance_ratio: r}) when is_float(r), do: r
  defp resolve_ratio(%{imbalance_ratio: r}) when is_integer(r), do: r * 1.0

  defp resolve_ratio(_config) do
    case System.get_env("OBI_IMBALANCE_RATIO") do
      nil -> 1.8
      s -> String.to_float(s)
    end
  end

  defp resolve_max_qty(%{max_qty: q}) when is_integer(q), do: q

  defp resolve_max_qty(_config) do
    case System.get_env("OBI_MAX_QTY") do
      nil -> 100
      s -> String.to_integer(s)
    end
  end
end
