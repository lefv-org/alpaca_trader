defmodule AlpacaTrader.Strategies.AvellanedaStoikov do
  @moduledoc """
  Avellaneda-Stoikov inventory-aware market making.

  Ported from Avellaneda & Stoikov (2008) "High-Frequency Trading in a Limit
  Order Book" (Quantitative Finance). The most influential MM paper still
  in active use; foundation of Hummingbot's MM strategy and many production
  deployments. See discussion in academic HFT literature including Kearns
  et al. (2010) on aggressive HFT profitability bounds and Baron-Brogaard-
  Kirilenko (2012) on empirical HFT trader profits.

  ## Core formulae (continuous time, infinite horizon approximation)

      σ²        = variance of log returns over recent window
      q         = current inventory (signed, normalised to [-1, +1])
      γ         = risk aversion (config: AS_GAMMA, default 0.1)
      κ         = order arrival intensity (config: AS_KAPPA, default 1.5)

      reservation_price r = mid − q · γ · σ² · mid
      optimal half-spread h = (γ·σ² + (2/γ)·ln(1 + γ/κ)) / 2 · mid

      bid_quote = r − h
      ask_quote = r + h

  We act when the live market crosses our quotes:

    * `market_ask ≤ bid_quote` ⇒ BUY  (someone willing to sell us cheaper than we'd post)
    * `market_bid ≥ ask_quote` ⇒ SELL (someone willing to buy from us higher than we'd post)

  Inventory skew: when `q > 0` (long), `r` shifts down → we lower our
  willingness to buy more and raise willingness to sell, mean-reverting
  position toward zero. Symmetric for `q < 0`.

  ## Resolution

  Polled at StrategyScanJob cadence (~minute). True MM is sub-second; this
  port captures the inventory-skew + spread-capture *logic* on minute bars.
  Upgrading to WebSocket quote streams (`stream_ticks/2`) would tighten
  resolution to seconds.

  ## Long-only mode

  When `LONG_ONLY_MODE=true` (default), SELL signals require an existing
  long position (reduce-only behaviour) and short entries are suppressed.

  ## Configuration (env-overridable)

    * `:symbols`         — equity symbols to make markets in (default: AS_SYMBOLS)
    * `:gamma`           — risk aversion (default: 0.1)
    * `:kappa`           — order arrival intensity (default: 1.5)
    * `:notional_per_leg` — $/order (default: 5.0; account-aware sizing comes from router)
    * `:target_inventory` — $-value at which |q| = 1 (default: 20.0)
    * `:window_bars`     — bars in σ estimation (default: 30)
    * `:min_bars`        — minimum bars before quoting (default: 20)
  """

  @behaviour AlpacaTrader.Strategy

  require Logger

  alias AlpacaTrader.Types.{Signal, Leg, FeedSpec}
  alias AlpacaTrader.Alpaca.Client
  alias AlpacaTrader.BarsStore

  # Conviction kept above default LLM gate threshold (0.5).
  @conviction 0.7

  @default_symbols ~w[SPY QQQ AAPL MSFT NVDA]
  @default_gamma 0.1
  @default_kappa 1.5
  @default_notional 5.0
  @default_target_inventory 20.0
  @default_window 30
  @default_min_bars 20

  # Anti-hysteresis (Hummingbot order_refresh_tolerance_pct): if a fresh
  # quote crosses our quote by less than this fraction of mid, suppress
  # the signal — avoid burning fees on noise-level re-quotes. 0.001 = 10 bps.
  @default_refresh_tolerance_pct 0.001

  # GLFT volatility-scaled half-spread coefficient (hftbacktest GLFT model).
  # half = (γσ² + (2/γ)ln(1+γ/κ)) * (1 + glft_c·σ) / 2
  # 0.0 disables (pure Avellaneda-Stoikov).
  @default_glft_c 0.0

  # Size-skew exponent (Hummingbot inventory eta transform). When inventory
  # q is positive, buys shrink by exp(-eta·q) and sells grow by exp(eta·q).
  # 0.0 disables (constant size).
  @default_size_eta 0.5

  # ── Strategy callbacks ────────────────────────────────────────────────────────

  @impl true
  def id, do: :avellaneda_stoikov

  @impl true
  def required_feeds do
    [%FeedSpec{venue: :alpaca, symbols: :whitelist, cadence: :minute}]
  end

  @impl true
  def init(config) do
    state = %{
      symbols: resolve_list(config, :symbols, "AS_SYMBOLS", @default_symbols),
      gamma: resolve_float(config, :gamma, "AS_GAMMA", @default_gamma),
      kappa: resolve_float(config, :kappa, "AS_KAPPA", @default_kappa),
      notional_per_leg:
        resolve_float(config, :notional_per_leg, "AS_NOTIONAL", @default_notional),
      target_inventory:
        resolve_float(config, :target_inventory, "AS_TARGET_INV", @default_target_inventory),
      window_bars: resolve_int(config, :window_bars, "AS_WINDOW", @default_window),
      min_bars: resolve_int(config, :min_bars, "AS_MIN_BARS", @default_min_bars),
      refresh_tolerance_pct:
        resolve_float(
          config,
          :refresh_tolerance_pct,
          "AS_REFRESH_TOLERANCE_PCT",
          @default_refresh_tolerance_pct
        ),
      glft_c: resolve_float(config, :glft_c, "AS_GLFT_C", @default_glft_c),
      size_eta: resolve_float(config, :size_eta, "AS_SIZE_ETA", @default_size_eta),
      open_positions: %{},
      # Last quoted bid/ask per symbol — drives anti-hysteresis suppression.
      last_quotes: %{}
    }

    Logger.info(
      "[AS] init symbols=#{inspect(state.symbols)} γ=#{state.gamma} κ=#{state.kappa} " <>
        "notional=#{state.notional_per_leg} target_inv=$#{state.target_inventory} " <>
        "refresh_tol=#{state.refresh_tolerance_pct} glft_c=#{state.glft_c} eta=#{state.size_eta}"
    )

    {:ok, state}
  end

  @impl true
  def scan(state, ctx) do
    long_only = Application.get_env(:alpaca_trader, :long_only_mode, true)

    case Client.latest_stock_quotes_with_sizes(state.symbols) do
      {:ok, quotes} when map_size(quotes) > 0 ->
        {signals, new_state} = evaluate_quotes(quotes, state, ctx, long_only)
        {:ok, signals, new_state}

      {:ok, _empty} ->
        {:ok, [], state}

      {:error, reason} ->
        Logger.warning("[AS] quote fetch failed: #{inspect(reason)}")
        {:ok, [], state}
    end
  end

  @impl true
  def exits(state, _ctx), do: {:ok, [], state}

  @impl true
  def on_fill(state, fill) do
    updated =
      case fill.side do
        :buy -> Map.update(state.open_positions, fill.symbol, 1, &(&1 + 1))
        :sell -> Map.update(state.open_positions, fill.symbol, -1, &(&1 - 1))
      end

    {:ok, %{state | open_positions: updated}}
  end

  # ── Core logic ────────────────────────────────────────────────────────────────

  defp evaluate_quotes(quotes, state, ctx, long_only) do
    Enum.reduce(quotes, {[], state}, fn {symbol, quote}, {sigs, st} ->
      case build_signal_for(symbol, quote, st, ctx, long_only) do
        {nil, new_st} -> {sigs, new_st}
        {sig, new_st} -> {[sig | sigs], new_st}
      end
    end)
  end

  defp build_signal_for(symbol, quote, state, ctx, long_only) do
    with {:ok, bid, ask} <- extract_bid_ask(quote),
         true <- bid > 0.0 and ask > 0.0,
         {:ok, sigma2} <- compute_sigma_squared(symbol, state) do
      mid = (bid + ask) / 2.0
      sigma = :math.sqrt(sigma2)
      q = inventory_norm(symbol, mid, ctx, state)

      # Inventory-skewed reservation price
      r = mid - q * state.gamma * sigma2 * mid

      # Optimal half-spread (in price units), with optional GLFT volatility
      # scaling (hftbacktest GLFT model). glft_c=0 → pure A-S.
      base_half =
        (state.gamma * sigma2 +
           2.0 / state.gamma * :math.log(1.0 + state.gamma / state.kappa)) / 2.0 * mid

      half_spread = base_half * (1.0 + state.glft_c * sigma)

      bid_quote = r - half_spread
      ask_quote = r + half_spread

      # Anti-hysteresis: skip if new quotes lie within tolerance of the
      # previously-seen quotes (Hummingbot order_refresh_tolerance_pct).
      if quotes_within_tolerance?(symbol, bid_quote, ask_quote, mid, state) do
        {nil, state}
      else
        new_state = put_in(state.last_quotes[symbol], {bid_quote, ask_quote})

        sig =
          cond do
            ask <= bid_quote ->
              maybe_buy_signal(symbol, ask, bid_quote, ask_quote, q, sigma2, new_state)

            bid >= ask_quote ->
              maybe_sell_signal(
                symbol,
                bid,
                bid_quote,
                ask_quote,
                q,
                sigma2,
                new_state,
                long_only
              )

            true ->
              nil
          end

        {sig, new_state}
      end
    else
      _ -> {nil, state}
    end
  end

  defp quotes_within_tolerance?(symbol, new_bid_q, new_ask_q, mid, state) do
    case Map.get(state.last_quotes, symbol) do
      nil ->
        false

      {prev_bid_q, prev_ask_q} ->
        tol = state.refresh_tolerance_pct * mid
        abs(new_bid_q - prev_bid_q) < tol and abs(new_ask_q - prev_ask_q) < tol
    end
  end

  defp maybe_buy_signal(symbol, ask, bid_q, ask_q, q, sigma2, state) do
    # Cap long inventory: don't keep stacking longs past target.
    if q >= 1.0 do
      nil
    else
      Signal.new(
        strategy: id(),
        conviction: @conviction,
        reason:
          "AS BUY #{symbol}: ask=#{f(ask)} ≤ bid_q=#{f(bid_q)} q=#{f(q)} " <>
            "σ²=#{f(sigma2)} ask_q=#{f(ask_q)}",
        ttl_ms: 60_000,
        legs: [
          %Leg{
            venue: :alpaca,
            symbol: symbol,
            side: :buy,
            size: Decimal.from_float(skewed_size(:buy, q, state)),
            size_mode: :notional,
            type: :market,
            limit_price: nil
          }
        ]
      )
    end
  end

  defp maybe_sell_signal(symbol, bid, bid_q, ask_q, q, sigma2, state, long_only) do
    cond do
      # In long-only mode, allow sell only if we hold inventory (reduce-only).
      long_only and q <= 0.0 ->
        nil

      # Don't short past target.
      q <= -1.0 ->
        nil

      true ->
        Signal.new(
          strategy: id(),
          conviction: @conviction,
          reason:
            "AS SELL #{symbol}: bid=#{f(bid)} ≥ ask_q=#{f(ask_q)} q=#{f(q)} " <>
              "σ²=#{f(sigma2)} bid_q=#{f(bid_q)}",
          ttl_ms: 60_000,
          legs: [
            %Leg{
              venue: :alpaca,
              symbol: symbol,
              side: :sell,
              size: Decimal.from_float(skewed_size(:sell, q, state)),
              size_mode: :notional,
              type: :market,
              limit_price: nil
            }
          ]
        )
    end
  end

  # ── Stats / inventory ────────────────────────────────────────────────────────

  defp extract_bid_ask(%{"bp" => bp, "ap" => ap}) when is_number(bp) and is_number(ap),
    do: {:ok, bp * 1.0, ap * 1.0}

  defp extract_bid_ask(%{"bid_price" => bp, "ask_price" => ap})
       when is_number(bp) and is_number(ap),
       do: {:ok, bp * 1.0, ap * 1.0}

  defp extract_bid_ask(_), do: :error

  defp compute_sigma_squared(symbol, state) do
    case BarsStore.get_closes(symbol) do
      {:ok, closes} when length(closes) >= 2 ->
        recent = Enum.take(closes, -state.window_bars)

        if length(recent) >= state.min_bars do
          {:ok, variance_log_returns(recent)}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp variance_log_returns(prices) do
    returns =
      prices
      |> Enum.zip(tl(prices))
      |> Enum.reduce([], fn {prev, curr}, acc ->
        if prev > 0 and curr > 0, do: [:math.log(curr / prev) | acc], else: acc
      end)

    case returns do
      [] ->
        0.0

      _ ->
        m = Enum.sum(returns) / length(returns)
        Enum.reduce(returns, 0.0, fn r, acc -> acc + (r - m) * (r - m) end) / length(returns)
    end
  end

  # Normalised inventory: signed position notional / target. Clamped to [-2, +2]
  # so a runaway position only contributes a bounded skew.
  defp inventory_norm(symbol, mid, ctx, state) do
    holdings_value = lookup_holdings_value(symbol, mid, ctx)

    raw = holdings_value / max(state.target_inventory, 1.0)
    raw |> max(-2.0) |> min(2.0)
  end

  defp lookup_holdings_value(symbol, mid, ctx) do
    cond do
      is_map(ctx) and is_map(Map.get(ctx, :positions)) ->
        case Map.get(ctx.positions, symbol) do
          %{qty: qty} when is_number(qty) -> qty * mid
          %{"qty" => qty} when is_number(qty) -> qty * mid
          _ -> 0.0
        end

      true ->
        0.0
    end
  end

  defp f(n) when is_float(n), do: Float.round(n, 4) |> Float.to_string()
  defp f(n), do: to_string(n)

  # Inventory-skewed size (Hummingbot eta transform).
  # When inventory q is positive (long), buys shrink and sells grow:
  #   buy_size  = notional * exp(-eta * q)
  #   sell_size = notional * exp( eta * q)
  # The exponential ensures size stays positive and decays smoothly. Floor
  # at 10% of notional so we never round to zero on tiny moves; cap at 2x
  # so size doesn't run away.
  defp skewed_size(side, q, %{notional_per_leg: base, size_eta: 0.0}), do: base * 1.0

  defp skewed_size(side, q, %{notional_per_leg: base, size_eta: eta}) do
    factor =
      case side do
        :buy -> :math.exp(-eta * q)
        :sell -> :math.exp(eta * q)
      end

    base * max(0.1, min(factor, 2.0))
  end

  # ── Config resolvers ──────────────────────────────────────────────────────────

  defp resolve_list(config, key, env, default) do
    case Map.get(config, key) do
      list when is_list(list) and list != [] ->
        list

      _ ->
        case System.get_env(env) do
          nil -> default
          "" -> default
          str -> String.split(str, ",", trim: true) |> Enum.map(&String.trim/1)
        end
    end
  end

  defp resolve_float(config, key, env, default) do
    case Map.get(config, key) do
      n when is_number(n) ->
        n * 1.0

      _ ->
        case System.get_env(env) do
          nil -> default
          "" -> default
          str -> parse_float(str, default)
        end
    end
  end

  defp resolve_int(config, key, env, default) do
    case Map.get(config, key) do
      n when is_integer(n) ->
        n

      _ ->
        case System.get_env(env) do
          nil -> default
          "" -> default
          str -> parse_int(str, default)
        end
    end
  end

  defp parse_float(str, default) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> default
    end
  end

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {i, _} -> i
      :error -> default
    end
  end
end
