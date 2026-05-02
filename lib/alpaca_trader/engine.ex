defmodule AlpacaTrader.Engine do
  @moduledoc """
  Single entry point for all trade decisions.
  """

  require Logger

  alias AlpacaTrader.Arbitrage.{
    BellmanFord,
    SubstituteDetector,
    ComplementDetector,
    AssetRelationships,
    RotationEvaluator
  }

  alias AlpacaTrader.Arbitrage.{SpreadCalculator, MeanReversion, HalfLifeManager}
  alias AlpacaTrader.{BarsStore, PairPositionStore}
  alias AlpacaTrader.Engine.OrderExecutor

  defmodule MarketContext do
    @derive Jason.Encoder
    defstruct [
      :symbol,
      :account,
      :position,
      :clock,
      :asset,
      :bars,
      :positions,
      :orders,
      :quotes,
      :prices
    ]
  end

  defmodule PurchaseContext do
    @derive Jason.Encoder
    defstruct [:action, :symbol, :reason, :qty, :side, :order, :timestamp]
  end

  defmodule ArbitragePosition do
    @derive Jason.Encoder
    defstruct [
      :result,
      :asset,
      :reason,
      :related_positions,
      :spread,
      :timestamp,
      :tier,
      :pair_asset,
      :direction,
      :hedge_ratio,
      :z_score,
      :action,
      :replaces
    ]
  end

  defmodule ArbitrageScanResult do
    @derive Jason.Encoder
    defstruct [:scanned, :hits, :opportunities, :executed, :trades, :timestamp]
  end

  # Order submission primitives live in OrderExecutor. Kept as a delegate
  # here so existing callers (tests, callers of Engine.execute_trade) are
  # unaffected by the extraction.
  defdelegate execute_trade(ctx, params), to: OrderExecutor

  # parse_float is used by a handful of engine-local helpers (order_notional,
  # etc). Keeping a private copy avoids a circular alias loop with OrderExecutor.
  defp parse_float(nil), do: nil

  defp parse_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float(n) when is_number(n), do: n * 1.0

  # ── is_in_arbitrage_position (position-aware) ─────────────

  @doc """
  The sole decision point for whether to trade.

  If already holding a pair position for this asset → check exit conditions.
  If not → cascade through entry tiers (1 → 2 → 3).
  """
  def is_in_arbitrage_position(%MarketContext{} = ctx, asset) do
    related =
      (ctx.positions || [])
      |> Enum.filter(fn p -> String.contains?(p["symbol"], asset) end)

    existing = PairPositionStore.find_open_for_asset(asset)

    case existing do
      %PairPositionStore.PairPosition{} = pos ->
        # In long-only mode, only the LONG leg's scan should drive exits.
        # When the asset being scanned is the SHORT leg, return no-op so
        # we don't try to sell something we never bought.
        if Application.get_env(:alpaca_trader, :long_only_mode, false) and
             not long_leg_of_pos?(pos, asset) do
          {:ok, %ArbitragePosition{result: false}}
        else
          check_exit_conditions(ctx, pos, asset, related)
        end

      nil ->
        check_entry_conditions(ctx, asset, related)
    end
  end

  # Convert Alpaca's compact crypto symbol back to PairPositionStore form.
  # E.g. "SOLUSD" -> "SOL/USD", "BTCUSDT" -> "BTC/USDT".
  defp restore_crypto_slash(s) when is_binary(s) do
    cond do
      String.ends_with?(s, "USDT") ->
        base = String.slice(s, 0, byte_size(s) - 4)
        "#{base}/USDT"

      String.ends_with?(s, "USDC") ->
        base = String.slice(s, 0, byte_size(s) - 4)
        "#{base}/USDC"

      String.ends_with?(s, "USD") ->
        base = String.slice(s, 0, byte_size(s) - 3)
        "#{base}/USD"

      String.ends_with?(s, "BTC") ->
        base = String.slice(s, 0, byte_size(s) - 3)
        "#{base}/BTC"

      true ->
        s
    end
  end

  defp long_leg_of_pos?(%{asset_a: a, direction: :long_a_short_b}, asset), do: a == asset
  defp long_leg_of_pos?(%{asset_b: b, direction: :long_b_short_a}, asset), do: b == asset
  defp long_leg_of_pos?(_, _), do: true

  # ── EXIT CONDITIONS ────────────────────────────────────────

  defp check_exit_conditions(ctx, pos, asset, related) do
    current = recompute_z_score(pos.asset_a, pos.asset_b)
    record_z_observation(pos, current)

    # Get current prices for P&L — live quotes first, then bars fallback
    price_a = get_live_price(ctx, pos.asset_a)
    price_b = get_live_price(ctx, pos.asset_b)
    pnl = compute_pnl(pos, price_a, price_b)

    # Tier-specific thresholds
    params = AssetRelationships.params_for(asset)
    profit_target = params.profit_target
    cut_loss = params.stop_loss

    # Update tracking — only count this scan as a real "bar held" when
    # recompute_z_score returned a fresh measurement. Without this, a
    # pair whose one leg has stale bars (no minute-cache + thin daily
    # data) accumulates bars_held without ever updating z, then trips
    # the half-life time-stop and forces a spread-loss exit on data
    # that never had a chance to mean-revert.
    z = if current, do: current.z_score, else: pos.current_z_score
    PairPositionStore.tick(pos.id, z, fresh: not is_nil(current))

    # Compute trend strength for flip gate
    spread_series = recompute_spread_series(pos.asset_a, pos.asset_b)
    trend = if spread_series, do: SpreadCalculator.trend_strength(spread_series), else: 0.0

    # Did z-score cross to opposite side? (flip candidate)
    z_crossed =
      current != nil and pos.entry_z_score != nil and
        ((pos.entry_z_score > 0 and current.z_score < -1.5) or
           (pos.entry_z_score < 0 and current.z_score > 1.5))

    # Flips do close + reverse-buy in the same scan, bypassing the
    # alpaca_holds_long_leg gate (which only runs on the :enter path).
    # On a small account each flip eats 2x spread (close + open) before
    # the new direction has any chance to be right. Default off; set
    # ENABLE_FLIPS=true to re-enable for accounts with real edge.
    flips_enabled =
      Application.get_env(:alpaca_trader, :enable_flips, false)

    can_flip =
      flips_enabled and z_crossed and trend > 25 and PairPositionStore.can_flip?(pos.id)

    cond do
      # 1. PROFIT TARGET: spread moved in our favor → SELL
      pnl != nil and pnl.profit_pct >= profit_target ->
        exit_signal(
          asset,
          related,
          pos,
          "TAKE PROFIT: #{Float.round(pnl.profit_pct, 2)}% gain ($#{Float.round(pnl.dollar_pnl, 2)}) [target: #{profit_target}%]"
        )

      # 2. FLIP: z-score crossed to opposite side + trending → reverse position
      can_flip ->
        flip_signal(asset, related, pos, current.z_score, trend, pnl)

      # 3. STOP LOSS: z-score diverged further
      current != nil and abs(current.z_score) >= pos.stop_z_threshold ->
        exit_signal(
          asset,
          related,
          pos,
          "STOP LOSS: z=#{current.z_score} exceeded #{pos.stop_z_threshold}"
        )

      # 4. CUT LOSS: P&L below tier-specific threshold
      pnl != nil and pnl.profit_pct <= cut_loss ->
        # If trending, flip instead of just cutting
        if flips_enabled and trend > 25 and PairPositionStore.can_flip?(pos.id) do
          flip_signal(asset, related, pos, z, trend, pnl)
        else
          exit_signal(
            asset,
            related,
            pos,
            "CUT LOSS: #{Float.round(pnl.profit_pct, 2)}% loss ($#{Float.round(pnl.dollar_pnl, 2)}) [limit: #{cut_loss}%]"
          )
        end

      # 5. TIME EXIT: half-life-aware time-stop (falls back to max_hold_bars when
      # half-life is unavailable). Keeps dead-money trades from decaying further.
      HalfLifeManager.should_time_stop?(pos.bars_held,
        half_life: pos.half_life,
        multiplier: Application.get_env(:alpaca_trader, :half_life_time_stop_mult, 2.0),
        fallback_bars: pos.max_hold_bars
      ) ->
        exit_signal(
          asset,
          related,
          pos,
          "TIME EXIT: held #{pos.bars_held} bars, P&L=#{format_pnl(pnl)}"
        )

      # 6. COINTEGRATION BROKEN: only after BOTH bars_held >= 5 AND we've
      # seen N consecutive nil z-score readings. Single-scan nils are
      # often transient (bar cache mid-refresh, brief data gap) — exiting
      # on first nil causes buy/sell churn even when the underlying pair
      # is fine.
      current == nil and pos.bars_held >= 5 and consecutive_nil_z(pos) >= 3 ->
        mark_broken_pair(pos.asset_a, pos.asset_b)

        exit_signal(
          asset,
          related,
          pos,
          "PAIR BROKEN: cannot compute spread (3+ scans), P&L=#{format_pnl(pnl)}"
        )

      # 7. Z-SCORE REVERSION: spread reverted to mean
      abs(current.z_score) <= pos.exit_z_threshold ->
        exit_signal(
          asset,
          related,
          pos,
          "Z-REVERSION: z=#{current.z_score}, P&L=#{format_pnl(pnl)}"
        )

      # 7. HOLD: still waiting
      true ->
        {:ok,
         %ArbitragePosition{
           result: false,
           asset: asset,
           reason:
             "HOLD: z=#{z}, P&L=#{format_pnl(pnl)} (#{pos.bars_held}/#{pos.max_hold_bars} bars)",
           related_positions: related,
           action: :hold,
           tier: pos.tier,
           pair_asset: if(pos.asset_a == asset, do: pos.asset_b, else: pos.asset_a),
           z_score: z,
           timestamp: DateTime.utc_now()
         }}
    end
  end

  defp compute_pnl(pos, price_a, price_b) do
    if pos.entry_price_a && pos.entry_price_b && price_a && price_b &&
         pos.entry_price_a > 0 && pos.entry_price_b > 0 do
      # P&L depends on direction
      {long_entry, long_current, short_entry, short_current} =
        case pos.direction do
          :long_a_short_b ->
            {pos.entry_price_a, price_a, pos.entry_price_b, price_b}

          :long_b_short_a ->
            {pos.entry_price_b, price_b, pos.entry_price_a, price_a}
        end

      long_pnl = (long_current - long_entry) / long_entry * 100
      short_pnl = (short_entry - short_current) / short_entry * 100
      profit_pct = (long_pnl + short_pnl) / 2
      dollar_pnl = long_current - long_entry + (short_entry - short_current)

      %{profit_pct: profit_pct, dollar_pnl: dollar_pnl, long_pnl: long_pnl, short_pnl: short_pnl}
    else
      nil
    end
  end

  # Live price: check snapshot quotes first (real-time), then bars (daily)
  defp get_live_price(%MarketContext{quotes: quotes}, symbol) when is_map(quotes) do
    case quotes do
      %{^symbol => %{"latestTrade" => %{"p" => price}}} when is_number(price) ->
        price

      %{^symbol => %{"latestQuote" => %{"ap" => ask, "bp" => bid}}}
      when is_number(ask) and is_number(bid) ->
        (ask + bid) / 2

      _ ->
        get_bars_price(symbol)
    end
  end

  defp get_live_price(%MarketContext{prices: prices}, symbol) when is_map(prices) do
    case prices do
      %{^symbol => %{"latestTrade" => %{"p" => price}}} -> price
      _ -> get_bars_price(symbol)
    end
  end

  defp get_live_price(_ctx, symbol), do: get_bars_price(symbol)

  defp get_bars_price(symbol) do
    case BarsStore.get_closes(symbol) do
      {:ok, closes} when closes != [] -> List.last(closes)
      _ -> nil
    end
  end

  defp format_pnl(nil), do: "n/a"

  defp format_pnl(%{profit_pct: pct, dollar_pnl: dollar}),
    do: "#{Float.round(pct, 2)}% ($#{Float.round(dollar, 2)})"

  defp exit_signal(asset, related, pos, reason) do
    {:ok,
     %ArbitragePosition{
       result: true,
       asset: asset,
       reason: reason,
       related_positions: related,
       action: :exit,
       tier: pos.tier,
       pair_asset: if(pos.asset_a == asset, do: pos.asset_b, else: pos.asset_a),
       direction: reverse_direction(pos.direction),
       hedge_ratio: pos.entry_hedge_ratio,
       z_score: pos.current_z_score,
       spread: pos.current_z_score,
       timestamp: DateTime.utc_now()
     }}
  end

  defp flip_signal(asset, related, pos, current_z, trend, pnl) do
    {:ok,
     %ArbitragePosition{
       result: true,
       asset: asset,
       reason:
         "FLIP: z=#{current_z} crossed (trend=#{trend}), P&L=#{format_pnl(pnl)}, flip##{pos.flip_count + 1}",
       related_positions: related,
       action: :flip,
       tier: pos.tier,
       pair_asset: if(pos.asset_a == asset, do: pos.asset_b, else: pos.asset_a),
       direction: reverse_direction(pos.direction),
       hedge_ratio: pos.entry_hedge_ratio,
       z_score: current_z,
       spread: current_z,
       timestamp: DateTime.utc_now()
     }}
  end

  defp reverse_direction(:long_a_short_b), do: :long_b_short_a
  defp reverse_direction(:long_b_short_a), do: :long_a_short_b

  # Use 1-minute bars for crypto pairs, daily bars for equities
  defp recompute_z_score(asset_a, asset_b) do
    with {:ok, closes_a} <- get_best_closes(asset_a),
         {:ok, closes_b} <- get_best_closes(asset_b) do
      len = min(length(closes_a), length(closes_b))
      a = Enum.take(closes_a, -len)
      b = Enum.take(closes_b, -len)
      SpreadCalculator.analyze(a, b)
    else
      _ -> nil
    end
  end

  defp recompute_spread_series(asset_a, asset_b) do
    with {:ok, closes_a} <- get_best_closes(asset_a),
         {:ok, closes_b} <- get_best_closes(asset_b) do
      len = min(length(closes_a), length(closes_b))

      if len >= 20 do
        a = Enum.take(closes_a, -len)
        b = Enum.take(closes_b, -len)
        ratio = SpreadCalculator.hedge_ratio(a, b)
        SpreadCalculator.spread_series(a, b, ratio)
      else
        nil
      end
    else
      _ -> nil
    end
  end

  # Crypto: prefer 1-minute bars (live), fall back to daily
  # Equity: use daily bars only
  defp get_best_closes(symbol) do
    if String.contains?(symbol, "/") do
      case AlpacaTrader.MinuteBarCache.get_closes(symbol) do
        {:ok, closes} when length(closes) >= 20 -> {:ok, closes}
        _ -> BarsStore.get_closes(symbol)
      end
    else
      BarsStore.get_closes(symbol)
    end
  end

  # ── ENTRY CONDITIONS (3-tier cascade) ──────────────────────

  defp check_entry_conditions(ctx, asset, related) do
    case try_tier_1(ctx, asset) do
      {:hit, arb} ->
        {:ok, %ArbitragePosition{arb | related_positions: related, action: :enter}}

      :miss ->
        case try_tier_2(asset) do
          {:hit, arb} ->
            maybe_rotate(arb, related)

          :miss ->
            case try_tier_3(asset) do
              {:hit, arb} ->
                maybe_rotate(arb, related)

              :miss ->
                {:ok,
                 %ArbitragePosition{
                   result: false,
                   asset: asset,
                   action: :hold,
                   reason: "no opportunity across all tiers",
                   related_positions: related,
                   tier: nil,
                   timestamp: DateTime.utc_now()
                 }}
            end
        end
    end
  end

  # One step of the graph relaxation spiral: check if this signal
  # should displace a stale position or enter normally.
  defp maybe_rotate(%ArbitragePosition{} = arb, related) do
    open = PairPositionStore.open_positions()

    case RotationEvaluator.evaluate(arb, open) do
      {:rotate, victim} ->
        Logger.info(
          "[Rotation] 🔄 #{arb.asset} (z=#{arb.z_score}) displaces #{victim.asset_a}↔#{victim.asset_b} (stale)"
        )

        {:ok,
         %ArbitragePosition{
           arb
           | related_positions: related,
             action: :rotate,
             replaces: victim.id
         }}

      :enter_normally ->
        {:ok, %ArbitragePosition{arb | related_positions: related, action: :enter}}

      :skip ->
        {:ok,
         %{
           arb
           | related_positions: related,
             action: :hold,
             result: false,
             reason: "signal weaker than all open positions (rotation skip)"
         }}
    end
  end

  defp try_tier_1(ctx, asset) do
    currency = asset |> String.split("/") |> hd()

    case ctx.quotes do
      quotes when is_map(quotes) and map_size(quotes) > 0 ->
        cycles = BellmanFord.detect_cycles(quotes)

        case BellmanFord.currency_in_cycles?(currency, cycles) do
          %{cycle: cycle, profit_pct: profit} ->
            {:hit,
             %ArbitragePosition{
               result: true,
               asset: asset,
               tier: 1,
               spread: profit,
               reason: "cycle: #{Enum.join(cycle, " → ")} (#{profit}%)",
               timestamp: DateTime.utc_now()
             }}

          nil ->
            :miss
        end

      _ ->
        :miss
    end
  end

  defp try_tier_2(asset) do
    case SubstituteDetector.detect(asset) do
      {:ok, %{z_score: z, hedge_ratio: ratio, asset_b: pair, direction: dir}} ->
        {:hit,
         %ArbitragePosition{
           result: true,
           asset: asset,
           tier: 2,
           spread: z,
           reason: "substitute spread z=#{z} (#{asset}↔#{pair})",
           pair_asset: pair,
           direction: dir,
           hedge_ratio: ratio,
           z_score: z,
           timestamp: DateTime.utc_now()
         }}

      {:ok, nil} ->
        :miss
    end
  end

  defp try_tier_3(asset) do
    case ComplementDetector.detect(asset) do
      {:ok, %{z_score: z, hedge_ratio: ratio, asset_b: pair, direction: dir}} ->
        {:hit,
         %ArbitragePosition{
           result: true,
           asset: asset,
           tier: 3,
           spread: z,
           reason: "complement spread z=#{z} (#{asset}↔#{pair})",
           pair_asset: pair,
           direction: dir,
           hedge_ratio: ratio,
           z_score: z,
           timestamp: DateTime.utc_now()
         }}

      {:ok, nil} ->
        :miss
    end
  end

  # ── scan_arbitrage / scan_and_execute ──────────────────────

  def scan_arbitrage(%MarketContext{} = ctx) do
    {scanned, hits} = do_scan(ctx)

    {:ok,
     %ArbitrageScanResult{
       scanned: scanned,
       hits: length(hits),
       opportunities: hits,
       executed: 0,
       trades: [],
       timestamp: DateTime.utc_now()
     }}
  end

  def scan_and_execute(%MarketContext{} = ctx) do
    # Cancel stale pending orders first — pending buy orders cause Alpaca's
    # PDT protection to block sells (it thinks the sell would complete a day trade)
    cancel_pending_orders(ctx)

    # Reap stale positions to free buying power before scanning
    reaped = reap_stale_positions(ctx)

    {scanned, hits} = do_scan(ctx)

    action_counts = hits |> Enum.frequencies_by(& &1.action)
    Logger.info("[Engine] hits by action: #{inspect(action_counts)}")

    # Cap :enter actions per scan so a 90+ opportunity batch can't blow past
    # the 60s scheduler window once each opp is gated through the LLM (which
    # can take 30s+ on Ollama timeouts). Manage actions (:exit/:flip/:rotate)
    # always run — they protect existing positions.
    max_entries = Application.get_env(:alpaca_trader, :max_entries_per_scan, 5)

    {entries, manage} = Enum.split_with(hits, &(&1.action == :enter))

    # Drop entries that the cheap pre-flight gates would refuse anyway
    # (PDT, orphan-blocked symbols). Otherwise the cap fills with doomed
    # equity candidates while real (crypto) opportunities never get a slot.
    tradeable_entries = Enum.reject(entries, &cheap_skip_entry?(ctx, &1))

    capped_entries =
      tradeable_entries
      |> Enum.sort_by(&entry_priority/1, :desc)
      |> Enum.take(max_entries)

    dropped = length(entries) - length(tradeable_entries)

    if dropped > 0 do
      Logger.info("[Engine] dropped #{dropped} entries via cheap pre-flight (PDT/orphan)")
    end

    if length(tradeable_entries) > max_entries do
      Logger.info(
        "[Engine] capping entries: #{length(tradeable_entries)} candidates → #{max_entries} (top by priority)"
      )
    end

    trades =
      Enum.flat_map(manage ++ capped_entries, fn arb ->
        case arb.action do
          :enter -> gate_and_enter(ctx, arb)
          :exit -> execute_exit(ctx, arb)
          :flip -> gate_and_flip(ctx, arb)
          :rotate -> gate_and_rotate(ctx, arb)
          _ -> []
        end
      end)

    executed = Enum.count(trades, &(&1.action in [:bought, :sold])) + length(reaped)

    {:ok,
     %ArbitrageScanResult{
       scanned: scanned,
       hits: length(hits),
       opportunities: hits,
       executed: executed,
       trades: trades ++ reaped,
       timestamp: DateTime.utc_now()
     }}
  end

  # ── CANCEL PENDING ORDERS ──────────────────────────────────────
  # Pending buy orders cause Alpaca's PDT protection to think that selling
  # the same symbol would create a day trade. Cancel them before reaping.

  defp cancel_pending_orders(%MarketContext{orders: orders}) when is_list(orders) do
    # Only cancel STALE pending orders (>5 min old) to clear PDT blocks.
    # Fresh pending orders are likely just-submitted and haven't filled
    # yet — cancelling them every 60s scan kills the bot's own buys
    # before they fill. Crypto market orders fill in <2 min normally,
    # so 5 min is a safe staleness threshold.
    cutoff = DateTime.add(DateTime.utc_now(), -300, :second)

    stale =
      Enum.filter(orders, fn o ->
        in_pending = o["status"] in ["new", "pending_new", "accepted", "partially_filled"]

        too_old =
          case parse_dt(o["created_at"]) do
            %DateTime{} = ts -> DateTime.compare(ts, cutoff) == :lt
            _ -> false
          end

        in_pending and too_old
      end)

    if stale != [] do
      Logger.info("[Reaper] cancelling #{length(stale)} stale (>5min) pending orders")

      Enum.each(stale, fn o ->
        AlpacaTrader.Alpaca.Client.cancel_order(o["id"])
      end)
    end
  end

  defp cancel_pending_orders(_ctx), do: :ok

  defp parse_dt(nil), do: nil

  defp parse_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil

  # ── STALE POSITION REAPER + DEADLOCK BREAKER ──────────────────
  # 1. Normal reap: close positions with negative P&L (losers).
  # 2. Deadlock break: if buying power is still too low to trade after reaping
  #    losers, close ANY closeable position (worst-performing first) to free capital.
  # Skips positions bought today (would be a day trade) and PDT-rejected symbols.

  @pdt_cache_key :reaper_pdt_blocked
  # retry PDT-blocked symbols after 1 hour
  @pdt_cache_ttl_s 3600

  defp reap_stale_positions(%MarketContext{} = ctx) do
    positions = ctx.positions || []
    market_open? = get_in(ctx.clock, ["is_open"]) == true
    pdt_blocked = get_pdt_blocked()

    # Phase 1: close losing positions
    losers =
      positions
      |> Enum.filter(fn pos ->
        symbol = pos["symbol"]
        not Map.has_key?(pdt_blocked, symbol) and stale_position?(pos, market_open?)
      end)

    reaped = close_positions(losers, "stale")

    # Phase 2: deadlock breaker — if we still can't afford an entry, close
    # closeable LOSING positions to free capital. Winning positions are
    # NEVER closed by deadlock break — that's a profitable mean-reversion
    # in progress; killing it locks in fees and forfeits alpha.
    if not can_afford_entry?(ctx) and reaped == [] do
      closeable =
        positions
        |> Enum.filter(fn pos ->
          symbol = pos["symbol"]
          plpc = parse_float(pos["unrealized_plpc"]) || 0.0

          not Map.has_key?(pdt_blocked, symbol) and
            closeable_position?(pos, market_open?) and
            plpc < 0
        end)
        |> Enum.sort_by(fn pos -> parse_float(pos["unrealized_plpc"]) || 0.0 end)

      if closeable != [] do
        Logger.info(
          "[Reaper] 🔓 DEADLOCK BREAK: buying power too low, closing #{length(closeable)} positions to free capital"
        )

        :persistent_term.put(:reaper_deadlock_logged, false)
        close_positions(closeable, "deadlock break")
      else
        # Log once, then stay quiet until the deadlock clears
        unless :persistent_term.get(:reaper_deadlock_logged, false) do
          Logger.info(
            "[Reaper] 🔒 deadlocked: all positions PDT-blocked or too small, waiting for PDT window to clear"
          )

          :persistent_term.put(:reaper_deadlock_logged, true)
        end

        []
      end
    else
      reaped
    end
  end

  defp close_positions(positions, reason_prefix) do
    Enum.flat_map(positions, fn pos ->
      symbol = pos["symbol"]
      unrealized = parse_float(pos["unrealized_pl"]) || 0.0
      pct = parse_float(pos["unrealized_plpc"]) || 0.0

      Logger.info(
        "[Reaper] 🪓 closing #{reason_prefix} #{symbol}: " <>
          "P&L=$#{Float.round(unrealized, 2)} (#{Float.round(pct * 100, 2)}%)"
      )

      case AlpacaTrader.Alpaca.Client.close_position(URI.encode(symbol)) do
        {:ok, order} ->
          Logger.info("[Reaper] ✅ closed #{symbol} status=#{order["status"]}")

          # Alpaca returns crypto symbols without the slash (e.g. "SOLUSD"
          # for "SOL/USD"). PairPositionStore tracks them with the slash,
          # so try both forms before giving up.
          case PairPositionStore.find_open_for_asset(symbol) ||
                 PairPositionStore.find_open_for_asset(restore_crypto_slash(symbol)) do
            %PairPositionStore.PairPosition{id: id, asset_a: a, asset_b: b} = pos ->
              PairPositionStore.close_position(id)
              # Also blacklist the pair AND both legs so we don't re-enter
              # the same configuration (or any pair targeting these legs)
              # on the next scan. Reaper closes are usually because the
              # long leg moved against us — chasing it back in immediately
              # is fee-bleed, not alpha.
              mark_broken_pair(a, b)
              mark_recently_closed_asset(a)
              mark_recently_closed_asset(b)

              # Log Reaper close to TradeLog so geometric P&L proofs see
              # every realized trade, not just engine-driven exits.
              log_reaper_close(pos, unrealized, pct, reason_prefix)

            _ ->
              :ok
          end

          [
            %PurchaseContext{
              action: :sold,
              symbol: symbol,
              reason: "#{reason_prefix}: P&L=$#{Float.round(unrealized, 2)}",
              qty: pos["qty"],
              side: "sell",
              order: order,
              timestamp: DateTime.utc_now()
            }
          ]

        {:error, %{"code" => 40_310_100} = _err} ->
          mark_pdt_blocked(symbol)

          Logger.debug(
            "[Reaper] 🔒 #{symbol} PDT-blocked, skipping for #{div(@pdt_cache_ttl_s, 60)} min"
          )

          []

        {:error, err} ->
          Logger.warning(
            "[Reaper] ⚠️ failed to close #{symbol}: #{inspect(err) |> String.slice(0..80)}"
          )

          []
      end
    end)
  end

  defp get_pdt_blocked do
    now = System.system_time(:second)

    case :persistent_term.get(@pdt_cache_key, nil) do
      nil ->
        %{}

      cache ->
        cache
        |> Enum.reject(fn {_sym, ts} -> now - ts > @pdt_cache_ttl_s end)
        |> Map.new()
    end
  end

  defp mark_pdt_blocked(symbol) do
    cache = get_pdt_blocked()
    :persistent_term.put(@pdt_cache_key, Map.put(cache, symbol, System.system_time(:second)))
  end

  # A position bought today would be a day trade if sold — skip it for non-crypto.
  defp bought_today?(pos) do
    asset_class = pos["asset_class"] || "us_equity"

    if asset_class == "crypto" do
      # crypto is exempt from PDT
      false
    else
      # Alpaca positions have qty_available and change_today;
      # if change_today != "0" the position was modified today
      change = parse_float(pos["change_today"]) || 0.0
      change != 0.0
    end
  end

  defp closeable_position?(pos, market_open?) do
    asset_class = pos["asset_class"] || "us_equity"
    market_value = parse_float(pos["market_value"]) || 0.0

    if abs(market_value) < 0.50 do
      false
    else
      is_crypto = asset_class == "crypto"
      can_close = is_crypto or market_open?
      can_close and not bought_today?(pos)
    end
  end

  defp stale_position?(pos, market_open?) do
    unrealized = parse_float(pos["unrealized_pl"]) || 0.0
    pct = parse_float(pos["unrealized_plpc"]) || 0.0

    # Threshold widened: mean-reversion strategies need to ride out small
    # adverse moves (the spread can dip 1-2% before reverting). Was
    # -0.5% which closed positions before reversion captured anything.
    # Now -3% — large enough to absorb noise, small enough to cut real
    # divergences. Configurable via REAPER_STALE_LOSS_PCT.
    threshold = Application.get_env(:alpaca_trader, :reaper_stale_loss_pct, -0.03)
    losing = unrealized < 0 and pct < threshold

    closeable_position?(pos, market_open?) and losing
  end

  # ── PRE-FLIGHT: cheap checks before expensive LLM call ──────

  defp can_afford_entry?(ctx) do
    buying_power = parse_float(get_in(ctx.account, ["buying_power"])) || 0.0
    notional = compute_notional(ctx)

    # Simple check: can we afford at least one trade's notional?
    buying_power >= notional
  end

  defp compute_notional(ctx) do
    equity = parse_float(get_in(ctx.account, ["equity"])) || 0.0
    notional_pct = Application.get_env(:alpaca_trader, :order_notional_pct, 0.001)
    max(equity * notional_pct, 1.0)
  end

  # ── LLM CONVICTION GATE ─────────────────────────────────────

  defp gate_and_enter(ctx, arb) do
    # Re-check the entry filter immediately before execution. Exits earlier
    # in the same scan may have set per-asset/pair cooldowns that the
    # scan-time filter couldn't see.
    cond do
      entry_for_already_held?(arb) ->
        Logger.info("[Engine] cooldown blocked entry on #{describe_arb(arb)}")
        shadow_record_blocked(arb, [:cooldown])
        []

      alpaca_holds_long_leg?(arb) ->
        Logger.info(
          "[Engine] alpaca-holds blocked entry on #{describe_arb(arb)} (long leg already on broker)"
        )

        shadow_record_blocked(arb, [:alpaca_holds])
        []

      true ->
        do_gate_and_enter(ctx, arb)
    end
  end

  defp do_gate_and_enter(ctx, arb) do
    # Cheap checks first, expensive LLM last.
    # 1. PDT block: when account is sub-$25k and recently traded, skip equity
    #    entries entirely (any same-day close = day trade, freezes account at 4).
    # 2. Can the account afford a new entry? (buying power > reserve + notional)
    # 3. Is the gain accumulator allowing entries?
    # 4. Portfolio sector/cluster caps (cheap, deterministic — runs before
    #    LLM so we don't waste 10–30s/call gating doomed candidates).
    # 5. Alt-data suppression
    # 6. LLM conviction gate
    cond do
      pdt_blocks_equity?(ctx, arb) ->
        Logger.debug(
          "[Pre-flight] ⏸ skipping #{describe_arb(arb)}: under PDT (sub-$25k, equity entry)"
        )

        shadow_record_blocked(arb, [:pdt])
        []

      not can_afford_entry?(ctx) ->
        Logger.debug("[Pre-flight] ⏸ skipping #{arb.asset}: insufficient buying power for entry")
        shadow_record_blocked(arb, [:buying_power])
        []

      not gain_allows_entry?(ctx) ->
        shadow_record_blocked(arb, [:gain_accumulator])
        []

      match?({:blocked, _}, AlpacaTrader.PortfolioRisk.allow_entry?(arb)) ->
        {:blocked, reason} = AlpacaTrader.PortfolioRisk.allow_entry?(arb)

        Logger.debug(
          "[Pre-flight] ⏸ skipping #{describe_arb(arb)}: portfolio gate (#{reason})"
        )

        shadow_record_blocked(arb, [:portfolio])
        []

      alt_data_suppressed?(arb.asset) ->
        Logger.info("[AltData] suppressing entry on #{arb.asset}: bearish/risk-off signal active")
        shadow_record_blocked(arb, [:alt_data])
        []

      true ->
        case AlpacaTrader.LLM.OpinionGate.evaluate(arb, ctx) do
          {:ok, %{decision: "suppress"}} ->
            Logger.info("[LLM Gate] SUPPRESSED #{arb.asset}: #{arb.reason}")
            shadow_record_blocked(arb, [:llm_suppress])
            []

          {:ok, %{conviction: c}} when c < 0.3 ->
            Logger.info("[LLM Gate] LOW CONVICTION #{Float.round(c, 2)} for #{arb.asset}")
            shadow_record_blocked(arb, [:llm_low_conviction])
            []

          {:ok, %{conviction: c, reasoning: r}} ->
            Logger.info(
              "[LLM Gate] CONFIRMED #{describe_arb(arb)} conviction=#{Float.round(c, 2)}: #{r}"
            )

            execute_entry(ctx, arb)

          _ ->
            execute_entry(ctx, arb)
        end
    end
  end

  # Priority for entry capping: prefer tier-1 (highest-confidence single-asset
  # opportunities), then tier-2 pairs by |z_score|, then tier-5 alt-data by
  # signal strength. Returns a tuple sortable in descending order.
  defp entry_priority(arb) do
    tier_score =
      case arb.tier do
        1 -> 100
        2 -> 80
        3 -> 70
        5 -> 50
        _ -> 0
      end

    z_score = if is_number(arb.z_score), do: abs(arb.z_score), else: 0.0
    spread = if is_number(arb.spread), do: abs(arb.spread), else: 0.0
    {tier_score, z_score, spread}
  end

  # Cheap, deterministic skip for entries the gates will reject anyway.
  # Used to drop candidates BEFORE the per-scan cap so doomed entries don't
  # crowd out tradeable ones. Mirrors the early branches of `gate_and_enter`.
  defp cheap_skip_entry?(ctx, arb) do
    pdt_blocks_equity?(ctx, arb) or alpaca_holds_long_leg?(arb)
  end

  # Block entries whose long leg (the side actually bought in long-only
  # mode) is already held on Alpaca. This catches the case where the
  # PairPositionStore has dropped tracking — e.g. after a ghost-close
  # that wiped the pair record while the underlying broker position
  # remained — and the bot would otherwise re-buy the same crypto on
  # every fresh signal. Reads the Reconciler's cached Alpaca-held set
  # so it does not add an HTTP call to the hot path.
  defp alpaca_holds_long_leg?(%{action: :enter, asset: a, pair_asset: b, direction: dir}) do
    long_leg =
      case dir do
        :long_a_short_b -> a
        :long_b_short_a -> b
        _ -> a
      end

    held =
      is_binary(long_leg) and AlpacaTrader.PositionReconciler.held_on_alpaca?(long_leg)

    Logger.debug(
      "[alpaca_holds] arb a=#{inspect(a)} b=#{inspect(b)} dir=#{inspect(dir)} long_leg=#{inspect(long_leg)} held=#{held}"
    )

    held
  end

  defp alpaca_holds_long_leg?(%{action: :enter, asset: a}) when is_binary(a) do
    held = AlpacaTrader.PositionReconciler.held_on_alpaca?(a)
    Logger.debug("[alpaca_holds] solo a=#{inspect(a)} held=#{held}")
    held
  end

  defp alpaca_holds_long_leg?(_), do: false

  # PDT (Pattern Day Trader) protection: an Alpaca account with equity
  # < $25k that day-trades 4 times in 5 days gets frozen. Bot strategies
  # routinely close same-day, so any equity entry under sub-$25k is a PDT
  # risk. Skip equity entries entirely while under PDT and not yet at the
  # $25k threshold. Crypto and pair-leg crypto remain allowed (24/7, no PDT
  # rules). Toggle off via :pdt_block_equity_entries=false.
  defp pdt_blocks_equity?(ctx, arb) do
    if Application.get_env(:alpaca_trader, :pdt_block_equity_entries, true) do
      equity = parse_float(get_in(ctx.account, ["equity"])) || 0.0
      under_pdt = equity < 25_000.0
      asset_is_crypto? = is_binary(arb.asset) and String.contains?(arb.asset, "/")
      pair_is_crypto? = is_binary(arb.pair_asset) and String.contains?(arb.pair_asset, "/")
      under_pdt and not (asset_is_crypto? and pair_is_crypto?)
    else
      false
    end
  end

  # Render the arb concisely for logs. For pair tiers it shows the pair
  # and direction so the reader can predict which leg will actually trade
  # (e.g. long-only mode buys `arb.pair_asset` when direction is
  # `:long_b_short_a`).
  defp describe_arb(%{tier: tier, asset: a, pair_asset: b, direction: dir})
       when tier in [2, 3] and not is_nil(b) do
    "#{a}↔#{b} #{dir}"
  end

  defp describe_arb(%{asset: a}), do: to_string(a)

  defp alt_data_suppressed?(asset) do
    threshold = Application.get_env(:alpaca_trader, :alt_data_suppress_threshold, 0.6)

    AlpacaTrader.AltData.SignalStore.active_for(asset)
    |> Enum.any?(fn sig ->
      sig.direction in [:bearish, :risk_off] and sig.strength > threshold
    end)
  end

  defp gate_and_flip(ctx, arb) do
    gain_ok? = gain_allows_entry?(ctx)

    case AlpacaTrader.LLM.OpinionGate.evaluate(arb, ctx) do
      {:ok, %{decision: "suppress"}} ->
        # Suppressed flip → still close the position to avoid leaving it unmanaged
        Logger.info("[LLM Gate] SUPPRESSED flip #{arb.asset}, exiting instead")
        execute_exit(ctx, arb)

      {:ok, %{conviction: c}} when c < 0.3 ->
        # Low conviction on flip → just exit, don't reverse
        Logger.info("[LLM Gate] LOW CONVICTION flip #{arb.asset}, exiting instead")
        execute_exit(ctx, arb)

      {:ok, %{conviction: c, reasoning: r}} ->
        Logger.info(
          "[LLM Gate] CONFIRMED flip #{describe_arb(arb)} conviction=#{Float.round(c, 2)}: #{r}"
        )

        if gain_ok?, do: execute_flip(ctx, arb), else: execute_exit(ctx, arb)

      _ ->
        if gain_ok?, do: execute_flip(ctx, arb), else: execute_exit(ctx, arb)
    end
  end

  # ── ROTATION: LLM gate → close victim → enter new ──────────

  defp gate_and_rotate(ctx, arb) do
    cond do
      not can_afford_entry?(ctx) ->
        Logger.debug("[Pre-flight] ⏸ skipping rotation #{arb.asset}: insufficient buying power")
        []

      not gain_allows_entry?(ctx) ->
        []

      true ->
        case AlpacaTrader.LLM.OpinionGate.evaluate(arb, ctx) do
          {:ok, %{decision: "suppress"}} ->
            Logger.info("[LLM Gate] SUPPRESSED rotation #{arb.asset}")
            []

          {:ok, %{conviction: c}} when c < 0.3 ->
            Logger.info(
              "[LLM Gate] LOW CONVICTION #{Float.round(c, 2)} for rotation #{arb.asset}"
            )

            []

          {:ok, %{conviction: c, reasoning: r}} ->
            Logger.info(
              "[LLM Gate] CONFIRMED rotation #{arb.asset} conviction=#{Float.round(c, 2)}: #{r}"
            )

            execute_rotate(ctx, arb)

          _ ->
            execute_rotate(ctx, arb)
        end
    end
  end

  defp execute_rotate(ctx, arb) do
    # Step 1: Close the victim position (free the capital)
    victim =
      case :ets.lookup(:pair_position_store, arb.replaces) do
        [{_id, pos}] -> pos
        [] -> nil
      end

    exit_trades =
      if victim do
        victim_arb = %ArbitragePosition{
          result: true,
          asset: victim.asset_a,
          pair_asset: victim.asset_b,
          direction: victim.direction,
          tier: victim.tier,
          action: :exit,
          reason: "ROTATED OUT: replaced by #{arb.asset}↔#{arb.pair_asset} (z=#{arb.z_score})",
          z_score: victim.current_z_score,
          hedge_ratio: victim.entry_hedge_ratio,
          timestamp: DateTime.utc_now()
        }

        Logger.info("[Rotation] 🔄 closing #{victim.asset_a}↔#{victim.asset_b} to free capital")
        execute_exit(ctx, victim_arb)
      else
        []
      end

    # Step 2: Enter the new signal (same as normal entry)
    Logger.info("[Rotation] 🔄 entering #{arb.asset}↔#{arb.pair_asset} z=#{arb.z_score}")
    entry_trades = execute_entry(ctx, arb)

    exit_trades ++ entry_trades
  end

  # ── ENTRY EXECUTION ────────────────────────────────────────

  defp execute_entry(ctx, arb) do
    pair_label = "#{arb.asset}↔#{arb.pair_asset}"

    cond do
      # Whitelist gate: only trade pairs that are robust across walk-forward
      # windows. When the whitelist is disabled or empty this is a no-op.
      not AlpacaTrader.Arbitrage.PairWhitelist.allowed?(arb.asset, arb.pair_asset) ->
        Logger.debug("[Trade] ⏸ HOLD pair #{pair_label} (not whitelisted)")
        shadow_record_blocked(arb, [:whitelist])
        []

      true ->
        case regime_gate(arb) do
          {:blocked, reason} ->
            Logger.info("[Trade] ⏸ HOLD pair #{pair_label} (regime): #{inspect(reason)}")
            shadow_record_blocked(arb, [:regime])
            []

          :ok ->
            case AlpacaTrader.PortfolioRisk.allow_entry?(arb) do
              {:blocked, reason} ->
                Logger.info("[Trade] ⏸ HOLD pair #{pair_label} (portfolio): #{reason}")
                shadow_record_blocked(arb, [:portfolio])
                []

              :ok ->
                trades = execute_entry_post_portfolio_gate(ctx, arb, pair_label)
                shadow_record_entry_result(arb, trades)
                trades
            end
        end
    end
  end

  # ── REGIME GATE ────────────────────────────────────────────
  # Block entries when realized vol is too high or when the spread has
  # drifted out of stationarity since the last whitelist build. Feature
  # flagged — defaults to :ok when disabled.

  defp regime_gate(arb) do
    with {:ok, closes_a} <- get_best_closes(arb.asset),
         {:ok, closes_b} <- get_best_closes(arb.pair_asset) do
      len = min(length(closes_a), length(closes_b))

      if len >= 20 do
        a = Enum.take(closes_a, -len)
        b = Enum.take(closes_b, -len)
        ratio = arb.hedge_ratio || SpreadCalculator.hedge_ratio(a, b)
        spread = SpreadCalculator.spread_series(a, b, ratio)

        regime_opts = [
          enabled: Application.get_env(:alpaca_trader, :regime_filter_enabled, false),
          max_realized_vol: Application.get_env(:alpaca_trader, :regime_max_realized_vol, 1.0),
          max_adf_pvalue: Application.get_env(:alpaca_trader, :regime_max_adf_pvalue)
        ]

        AlpacaTrader.RegimeDetector.allow_entry?(
          %{spread: spread, symbol_a_closes: a, bar_frequency: :hourly},
          regime_opts
        )
      else
        :ok
      end
    else
      _ -> :ok
    end
  end

  defp execute_entry_post_portfolio_gate(ctx, arb, pair_label) do
    order_params = build_entry_params(ctx, arb)

    trades =
      case order_params do
        %{pair: true, legs: legs} ->
          OrderExecutor.execute_pair_atomic(ctx, legs, pair_label, :entry)

        params ->
          # Use the symbol actually being traded — in long-only mode the
          # buy leg may be arb.pair_asset (direction :long_b_short_a), not
          # arb.asset. Fall back to arb.asset for tier-1 entries.
          leg_symbol = Map.get(params, "symbol") || arb.asset
          trade_ctx = OrderExecutor.build_leg_context(ctx, leg_symbol)
          {:ok, purchase} = OrderExecutor.execute_trade(trade_ctx, params)
          [purchase]
      end

    # Track the position if any leg executed
    if arb.tier in [2, 3] and Enum.any?(trades, &(&1.action in [:bought, :sold])) do
      spread_series = recompute_spread_series(arb.asset, arb.pair_asset)
      half_life = spread_series && MeanReversion.half_life(spread_series)

      PairPositionStore.open_position(%{
        asset_a: arb.asset,
        asset_b: arb.pair_asset,
        direction: arb.direction,
        tier: arb.tier,
        z_score: arb.z_score,
        hedge_ratio: arb.hedge_ratio,
        entry_price_a: get_live_price(ctx, arb.asset),
        entry_price_b: get_live_price(ctx, arb.pair_asset),
        half_life: half_life
      })
    end

    trades
  end

  # ── EXIT EXECUTION ─────────────────────────────────────────

  defp execute_exit(ctx, arb) do
    # Close the position: reverse the original direction
    exit_params = build_exit_params(ctx, arb)
    pair_label = "#{arb.asset}↔#{arb.pair_asset}"

    shadow_record(%{
      timestamp: DateTime.utc_now(),
      pair: shadow_pair(arb),
      event: :exit_signal,
      status: :would_exit,
      z_score: shadow_z(arb)
    })

    trades =
      case exit_params do
        %{pair: true, legs: legs} ->
          OrderExecutor.execute_pair_atomic(ctx, legs, pair_label, :exit)

        params ->
          # Use the symbol actually being sold — in long-only mode this may
          # be arb.pair_asset, not arb.asset. Fall back to arb.asset for
          # tier-1 exits.
          leg_symbol = Map.get(params, "symbol") || arb.asset
          trade_ctx = OrderExecutor.build_leg_context(ctx, leg_symbol)
          {:ok, purchase} = OrderExecutor.execute_trade(trade_ctx, params)
          [purchase]
      end

    # Close the tracked position only if the exit actually executed.
    # If both legs were blocked (e.g., PDT), leave the position open so a
    # later tick can retry. Closing the tracker here would orphan the
    # real broker-side position.
    if OrderExecutor.pair_executed?(trades) do
      pos = PairPositionStore.find_open_for_asset(arb.asset)

      if pos do
        log_closed_trade(pos, arb, ctx, trades, :exit)
        PairPositionStore.close_position(pos.id)
      end
    end

    trades
  end

  defp log_reaper_close(pos, unrealized, pct, reason_prefix) do
    AlpacaTrader.TradeLog.record(%{
      pair: "#{pos.asset_a}-#{pos.asset_b}",
      tier: pos.tier,
      direction: "#{pos.direction}",
      entry_z: pos.entry_z_score,
      exit_z: pos.current_z_score,
      entry_price_a: pos.entry_price_a,
      entry_price_b: pos.entry_price_b,
      bars_held: pos.bars_held,
      pnl_dollar: unrealized,
      pnl_pct: pct * 100,
      reason: "reaper_#{reason_prefix}",
      entry_time: pos.entry_time && DateTime.to_iso8601(pos.entry_time),
      exit_time: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  # Record a closed trade to the append-only TradeLog for post-hoc analysis.
  # Captures the context at entry, the exit trigger, and the realized P&L.
  defp log_closed_trade(pos, arb, ctx, _trades, reason) do
    price_a = get_live_price(ctx, pos.asset_a)
    price_b = get_live_price(ctx, pos.asset_b)
    pnl = compute_pnl(pos, price_a, price_b)

    if pnl && is_number(pnl.dollar_pnl) and pnl.dollar_pnl < 0 do
      mark_recently_lost_asset(pos.asset_a)
      mark_recently_lost_asset(pos.asset_b)
    end

    AlpacaTrader.TradeLog.record(%{
      pair: "#{pos.asset_a}-#{pos.asset_b}",
      tier: pos.tier,
      direction: "#{pos.direction}",
      entry_z: pos.entry_z_score,
      exit_z: pos.current_z_score,
      entry_price_a: pos.entry_price_a,
      entry_price_b: pos.entry_price_b,
      exit_price_a: price_a,
      exit_price_b: price_b,
      hedge_ratio: pos.entry_hedge_ratio,
      bars_held: pos.bars_held,
      flip_count: pos.flip_count,
      consecutive_losses: pos.consecutive_losses,
      pnl_dollar: pnl && pnl.dollar_pnl,
      pnl_pct: pnl && pnl.profit_pct,
      reason: to_string(reason),
      arb_reason: arb && arb.reason,
      entry_time: pos.entry_time && DateTime.to_iso8601(pos.entry_time),
      exit_time: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  # ── FLIP EXECUTION: close old + open reversed ──────────────

  defp execute_flip(ctx, %ArbitragePosition{} = arb) do
    # Step 1: Close the current position (same as exit)
    exit_trades = execute_exit(ctx, arb)
    exit_closed? = OrderExecutor.pair_executed?(exit_trades)

    # Step 2: Open the reversed position — but only if the exit actually
    # closed. If exit was blocked (PDT, etc.), entering here would leave us
    # with TWO positions for the same asset: the original plus the reversed.
    entry_trades =
      if exit_closed? do
        reversed_arb = %ArbitragePosition{arb | direction: arb.direction, action: :enter}
        execute_entry(ctx, reversed_arb)
      else
        Logger.info(
          "[Flip] exit blocked — skipping reversed entry for #{arb.asset}↔#{arb.pair_asset}"
        )

        []
      end

    # Step 3: Track the flip in PairPositionStore
    was_profitable = exit_closed?

    case PairPositionStore.find_open_for_asset(arb.asset) do
      %PairPositionStore.PairPosition{} = pos ->
        :ets.insert(:pair_position_store, {
          pos.id,
          %PairPositionStore.PairPosition{
            pos
            | flip_count: pos.flip_count + 1,
              consecutive_losses: if(was_profitable, do: 0, else: pos.consecutive_losses + 1),
              last_flip_time: DateTime.utc_now()
          }
        })

      _ ->
        :ok
    end

    exit_trades ++ entry_trades
  end

  # ── ORDER PARAMS BUILDERS ──────────────────────────────────

  # Default (fixed) notional sizing. Takes optional arb so vol-scaled mode can
  # compute a per-pair size based on spread volatility.
  defp order_notional(ctx, arb \\ nil) do
    equity = parse_float(get_in(ctx.account, ["equity"])) || 0.0
    pct = Application.get_env(:alpaca_trader, :order_notional_pct, 0.001)
    fixed_notional = Float.round(equity * pct, 2)

    base_notional =
      case {position_sizing_mode(), arb} do
        {:vol_scaled, %ArbitragePosition{tier: tier, asset: a, pair_asset: b, hedge_ratio: hr}}
        when tier in [2, 3] and is_binary(a) and is_binary(b) ->
          vol_scaled_notional(equity, a, b, hr, fixed_notional)

        _ ->
          fixed_notional
      end

    notional =
      base_notional
      |> apply_half_life_size_multiplier(arb)
      |> apply_kelly_cap(equity)
      |> apply_cash_cap(ctx)

    # Alpaca minimum notional is $1
    to_string(max(Float.round(notional, 2), 1.0))
  end

  # Cap notional at half of available cash so a $5 trade doesn't reject when
  # only $4 is free. Without this, equity*pct ignores other open orders'
  # locked cash and produces predictable `insufficient balance for USD`
  # rejections. Half is the safety margin (a pair entry submits two legs).
  defp apply_cash_cap(notional, ctx) do
    cash =
      parse_float(get_in(ctx.account, ["cash"])) ||
        parse_float(get_in(ctx.account, ["buying_power"])) ||
        0.0

    cap_pct = Application.get_env(:alpaca_trader, :cash_cap_pct, 0.5)
    cap = cash * cap_pct
    if cap > 0, do: min(notional, cap), else: notional
  end

  # Optional Kelly-fractional ceiling: clips notional at
  # (fraction * full_kelly * equity), capped at `kelly_max_cap_pct * equity`.
  # Uses lifetime stats from TradeLog. Off by default.
  defp apply_kelly_cap(notional, equity) do
    if Application.get_env(:alpaca_trader, :kelly_enabled, false) and equity > 0 do
      stats =
        try do
          AlpacaTrader.TradeLog.performance_stats()
        catch
          :exit, _ -> %{}
        end

      cap =
        AlpacaTrader.Arbitrage.KellySizer.size_cap(equity, stats,
          fraction: Application.get_env(:alpaca_trader, :kelly_fraction, 0.5),
          max_cap_pct: Application.get_env(:alpaca_trader, :kelly_max_cap_pct, 0.05)
        )

      if cap > 0, do: min(notional, cap), else: notional
    else
      notional
    end
  end

  # Optional size-by-half-life: scales notional inversely with the OU half-life
  # of the pair's spread (clamped by HalfLifeManager). Off by default.
  defp apply_half_life_size_multiplier(base_notional, arb) do
    if Application.get_env(:alpaca_trader, :half_life_size_enabled, false) do
      hl =
        case arb do
          %ArbitragePosition{tier: tier, asset: a, pair_asset: b}
          when tier in [2, 3] and is_binary(a) and is_binary(b) ->
            case recompute_spread_series(a, b) do
              nil -> nil
              spread -> MeanReversion.half_life(spread)
            end

          _ ->
            nil
        end

      base_notional * HalfLifeManager.size_multiplier(hl)
    else
      base_notional
    end
  end

  # Vol-scaled sizing: notional s.t. each position risks the same dollar amount.
  # notional = (equity * target_risk_pct) / (spread_std_pct * stop_z)
  # Clamped to [0.25x, 4x] of the fixed notional as a safety bound.
  defp vol_scaled_notional(equity, asset_a, asset_b, hedge_ratio, fixed_notional) do
    with {:ok, closes_a} <- BarsStore.get_closes(asset_a),
         {:ok, closes_b} <- BarsStore.get_closes(asset_b),
         true <- length(closes_a) >= 30 and length(closes_b) >= 30,
         l = min(length(closes_a), length(closes_b)),
         ca = Enum.take(closes_a, -l),
         cb = Enum.take(closes_b, -l),
         hr = hedge_ratio || SpreadCalculator.hedge_ratio(ca, cb) do
      spread = SpreadCalculator.spread_series(ca, cb, hr)
      n = length(spread)
      mean_spread = Enum.sum(spread) / n

      variance =
        Enum.reduce(spread, 0.0, fn x, acc -> acc + :math.pow(x - mean_spread, 2) end) / n

      std = :math.sqrt(variance)
      mean_price = Enum.sum(ca) / length(ca)

      # Convert spread std (absolute) to a fraction of the asset price
      spread_std_pct = if mean_price > 0, do: std / mean_price, else: 0.01

      target_risk_pct = Application.get_env(:alpaca_trader, :target_risk_pct, 0.001)
      stop_z = Application.get_env(:alpaca_trader, :stop_z_threshold, 4.0)

      if spread_std_pct > 0 and stop_z > 0 do
        raw = equity * target_risk_pct / (spread_std_pct * stop_z)
        raw |> min(fixed_notional * 4.0) |> max(fixed_notional * 0.25)
      else
        fixed_notional
      end
    else
      _ -> fixed_notional
    end
  end

  defp position_sizing_mode do
    case Application.get_env(:alpaca_trader, :position_sizing_mode, :fixed) do
      mode when mode in [:fixed, :vol_scaled] -> mode
      _ -> :fixed
    end
  end

  @doc false
  # Public only so EngineLongOnlyTest can exercise the flag-conditional
  # branches without end-to-end scaffolding. Not intended as stable API.
  def build_entry_params(ctx, %ArbitragePosition{tier: 1} = arb) do
    %{
      "side" => if(arb.spread && arb.spread < 0, do: "sell", else: "buy"),
      "notional" => order_notional(ctx),
      "type" => "market"
    }
  end

  def build_entry_params(ctx, %ArbitragePosition{tier: tier} = arb) when tier in [2, 3] do
    {long_sym, short_sym} =
      case arb.direction do
        :long_a_short_b -> {arb.asset, arb.pair_asset}
        :long_b_short_a -> {arb.pair_asset, arb.asset}
      end

    notional = order_notional(ctx, arb)

    if Application.get_env(:alpaca_trader, :long_only_mode, false) do
      # Long-only rotation: skip the short leg entirely. Only the buy leg
      # is sent to the broker. The pair relationship is still recorded via
      # PairPositionStore for cointegration tracking + rotation.
      _ = short_sym

      %{
        "symbol" => long_sym,
        "side" => "buy",
        "notional" => notional,
        "type" => "market"
      }
    else
      %{
        pair: true,
        legs: [
          %{
            "symbol" => long_sym,
            "side" => "buy",
            "notional" => notional,
            "type" => "market",
            "pair_leg" => true
          },
          %{
            "symbol" => short_sym,
            "side" => "sell",
            "notional" => notional,
            "type" => "market",
            "pair_leg" => true
          }
        ]
      }
    end
  end

  def build_entry_params(ctx, _arb),
    do: %{"side" => "buy", "notional" => order_notional(ctx), "type" => "market"}

  @doc false
  # See build_entry_params/2 — exposed for targeted tests only.
  def build_exit_params(ctx, %ArbitragePosition{tier: tier} = arb) when tier in [2, 3] do
    # Reverse the entry: sell what was bought, buy back what was shorted
    {sell_sym, buy_sym} =
      case arb.direction do
        :long_a_short_b -> {arb.asset, arb.pair_asset}
        :long_b_short_a -> {arb.pair_asset, arb.asset}
      end

    notional = order_notional(ctx, arb)

    if Application.get_env(:alpaca_trader, :long_only_mode, false) do
      # Long-only exit: sell the long leg. Buying back the short leg is a
      # no-op since we never took the short position.
      # NOTE: log_closed_trade still reads prices for both asset_a and
      # asset_b — in long-only mode the short-leg price change does not
      # represent realized PnL. Follow-up: adjust PnL math for long-only.
      _ = buy_sym

      %{
        "symbol" => sell_sym,
        "side" => "sell",
        "notional" => notional,
        "type" => "market"
      }
    else
      %{
        pair: true,
        legs: [
          %{
            "symbol" => sell_sym,
            "side" => "sell",
            "notional" => notional,
            "type" => "market",
            "pair_leg" => true
          },
          %{
            "symbol" => buy_sym,
            "side" => "buy",
            "notional" => notional,
            "type" => "market",
            "pair_leg" => true
          }
        ]
      }
    end
  end

  def build_exit_params(ctx, arb) do
    %{
      "side" => "sell",
      "notional" => order_notional(ctx),
      "type" => "market",
      "symbol" => arb.asset
    }
  end

  # ── HELPERS ────────────────────────────────────────────────

  defp gain_allows_entry?(ctx) do
    equity = parse_float(get_in(ctx.account, ["equity"]))
    AlpacaTrader.GainAccumulatorStore.allow_entry?(equity)
  end

  defp do_scan(ctx) do
    market_open? = get_in(ctx.clock, ["is_open"]) == true
    relationship_symbols = AssetRelationships.all_symbols() |> MapSet.new()

    # Also include assets with open positions (for exit checks)
    open_symbols =
      PairPositionStore.open_positions()
      |> Enum.flat_map(fn p -> [p.asset_a, p.asset_b] end)
      |> MapSet.new()

    all_symbols = MapSet.union(relationship_symbols, open_symbols)

    assets =
      AlpacaTrader.AssetStore.all()
      |> Enum.filter(fn asset ->
        is_crypto = asset["class"] == "crypto"
        is_known = asset["symbol"] in all_symbols

        if market_open? do
          # Market open: trade everything
          is_crypto or is_known
        else
          # Market closed: crypto only (has live 1-min bars)
          is_crypto or (is_known and String.contains?(asset["symbol"], "/"))
        end
      end)

    # Refresh 1-minute bars for all crypto symbols we're scanning
    crypto_syms = assets |> Enum.filter(&(&1["class"] == "crypto")) |> Enum.map(& &1["symbol"])
    AlpacaTrader.MinuteBarCache.refresh(crypto_syms)

    # Known asset scan (Tier 1/2/3 + exit checks)
    results =
      Enum.map(assets, fn asset ->
        {:ok, arb} = is_in_arbitrage_position(ctx, asset["symbol"])
        arb
      end)

    # Discovery scan: rotate through new stocks each iteration
    discovery_hits = discover_new_pairs()

    raw_hits = Enum.filter(results, & &1.result) ++ discovery_hits

    # Drop entries on assets that already have an open pair position. The
    # store-level dedup prevents duplicate records but the scanner still
    # emits identical signals every cycle, causing the same symbol to be
    # bought 8+ times. Skip them here so they never reach the cap.
    store_filtered = Enum.reject(raw_hits, &entry_for_already_held?/1)

    # Within-batch long-leg dedup. Multiple discovery signals on the same
    # scan can target the same long leg (e.g. 3 different pairs all buying
    # LINK). Without this, all 3 fire because the store-level filter
    # checks state BEFORE any entry executes. Keep highest-priority one.
    deduped_hits = dedup_by_long_leg(store_filtered)

    dropped = length(raw_hits) - length(deduped_hits)

    if dropped > 0 do
      Logger.debug("[Engine] dropped #{dropped} re-entries on already-held pairs")
    end

    {length(results) + length(discovery_hits), deduped_hits}
  end

  # In-process cooldowns for recently-closed pairs and assets.
  # `:engine_broken_pairs` keys by sorted pair tuple; entries blocked when
  #   any signal targets that exact pair.
  # `:engine_recent_close_assets` keys by the long leg of the just-closed
  #   position; blocks re-entry on any pair whose long leg matches —
  #   prevents the same crypto from being bought via multiple pair
  #   signals after a fresh close.
  @broken_pairs_table :engine_broken_pairs
  @recent_close_assets_table :engine_recent_close_assets
  @recent_loss_assets_table :engine_recent_loss_assets
  @broken_pair_cooldown_ms 60 * 60 * 1000
  # Cooldown after closing a position. The original 2-min value assumed
  # genuine HFT cadence; in practice on a $99 paper account the bot
  # bled spread by round-tripping the same crypto pair every 3-4 min
  # (closed ETH at \$2305 then re-bought at \$2356 minutes later). 10 min
  # gives the z-score room to drift fully back without immediate reentry,
  # while still allowing multiple round-trips per session on real signals.
  # Override via :recent_close_cooldown_ms application env.
  @recent_close_cooldown_ms 10 * 60 * 1000
  # Loss-aware cooldown: when the most recent close on an asset realised
  # a loss, extend the no-re-entry window to 30 min. Stops the bot from
  # paying spread to round-trip the same asset multiple times within an
  # adverse session — saw 7 ETH/USD round-trips in one hour bleeding
  # ~25-50 bps each. Override via ENGINE_LOSS_COOLDOWN_MS.
  @recent_loss_cooldown_ms 30 * 60 * 1000

  # No-op: tables are created/owned by PairPositionStore.init/1. Calling
  # :ets.new from a transient scheduler task would set the task as owner
  # and the table would die when the task exited.
  defp ensure_broken_pair_table, do: @broken_pairs_table
  defp ensure_recent_close_assets_table, do: @recent_close_assets_table

  defp broken_pair_key(a, b) do
    [a, b] |> Enum.sort() |> Enum.join("|")
  end

  defp mark_broken_pair(a, b) when is_binary(a) and is_binary(b) do
    ensure_broken_pair_table()
    :ets.insert(@broken_pairs_table, {broken_pair_key(a, b), System.monotonic_time(:millisecond)})
    :ok
  end

  defp mark_recently_closed_asset(asset) when is_binary(asset) do
    ensure_recent_close_assets_table()

    :ets.insert(
      @recent_close_assets_table,
      {asset, System.monotonic_time(:millisecond)}
    )

    Logger.info("[Engine] cooldown: marked #{asset} closed")
    :ok
  end

  defp recently_closed_asset?(asset) when is_binary(asset) do
    ttl =
      Application.get_env(:alpaca_trader, :recent_close_cooldown_ms, @recent_close_cooldown_ms)

    PairPositionStore.asset_closed_recently?(asset, ttl) or
      recently_lost_asset?(asset)
  end

  defp recently_closed_asset?(_), do: false

  # Loss-aware cooldown: returns true if the asset was last closed at a
  # loss within @recent_loss_cooldown_ms. Set via mark_recently_lost_asset/1
  # from log_closed_trade when pnl_dollar < 0.
  defp recently_lost_asset?(asset) when is_binary(asset) do
    ttl = Application.get_env(:alpaca_trader, :recent_loss_cooldown_ms, @recent_loss_cooldown_ms)

    case :ets.whereis(@recent_loss_assets_table) do
      :undefined ->
        false

      _ ->
        case :ets.lookup(@recent_loss_assets_table, asset) do
          [{_, ts}] ->
            now = System.monotonic_time(:millisecond)
            now - ts < ttl

          _ ->
            false
        end
    end
  end

  defp mark_recently_lost_asset(asset) when is_binary(asset) do
    case :ets.whereis(@recent_loss_assets_table) do
      :undefined ->
        :ok

      _ ->
        :ets.insert(@recent_loss_assets_table, {asset, System.monotonic_time(:millisecond)})
        Logger.info("[Engine] loss-cooldown: marked #{asset} loss-closed")
        :ok
    end
  end

  defp mark_recently_lost_asset(_), do: :ok

  @doc """
  Bootstrap the in-memory loss-cooldown ETS table from the persistent
  TradeLog on startup. Without this, every bot restart resets the
  cooldown table — which on a fast-iterating dev loop means the
  bot's anti-bleed protection only activates if a fresh loss happens
  *after* the latest restart. Reads the last hour of log entries and
  marks any asset that closed at a loss within @recent_loss_cooldown_ms.

  Callable from Application.start/2. Errors are swallowed: a missing
  or malformed log file should not block boot.
  """
  def bootstrap_loss_cooldown do
    :ets.whereis(@recent_loss_assets_table)
    |> case do
      :undefined ->
        :ok

      _ ->
        try do
          ttl = Application.get_env(:alpaca_trader, :recent_loss_cooldown_ms, @recent_loss_cooldown_ms)
          cutoff_iso = DateTime.utc_now() |> DateTime.add(-ttl, :millisecond) |> DateTime.to_iso8601()

          AlpacaTrader.TradeLog.read_all()
          |> Enum.filter(fn entry ->
            pnl = entry["pnl_dollar"]
            exit_t = entry["exit_time"] || entry["logged_at"]
            is_number(pnl) and pnl < 0 and is_binary(exit_t) and exit_t >= cutoff_iso
          end)
          |> Enum.each(fn entry ->
            case String.split(entry["pair"] || "", "-", parts: 2) do
              [a, b] ->
                ts = parse_exit_ts(entry["exit_time"] || entry["logged_at"])
                if ts do
                  :ets.insert(@recent_loss_assets_table, {a, ts})
                  :ets.insert(@recent_loss_assets_table, {b, ts})
                end

              _ ->
                :ok
            end
          end)

          n = :ets.info(@recent_loss_assets_table, :size)
          Logger.info("[Engine] loss-cooldown bootstrap: #{n} entries seeded from TradeLog")
        rescue
          e ->
            Logger.warning("[Engine] loss-cooldown bootstrap skipped: #{Exception.message(e)}")
        end

        :ok
    end
  end

  defp parse_exit_ts(nil), do: nil

  defp parse_exit_ts(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        # Convert wall clock to monotonic-equivalent: now_mono - (now_wall - dt)
        now_wall = DateTime.utc_now()
        diff_ms = DateTime.diff(now_wall, dt, :millisecond)
        System.monotonic_time(:millisecond) - diff_ms

      _ ->
        nil
    end
  end

  @doc false
  # Public bridge so OrderExecutor can blacklist a pair after a soft sync-close.
  def mark_broken_pair_external(a, b) when is_binary(a) and is_binary(b) do
    mark_broken_pair(a, b)
    mark_recently_closed_asset(a)
    mark_recently_closed_asset(b)
  end

  defp recently_broken?(a, b) when is_binary(a) and is_binary(b) do
    ensure_broken_pair_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@broken_pairs_table, broken_pair_key(a, b)) do
      [{_, ts}] -> now - ts < @broken_pair_cooldown_ms
      _ -> false
    end
  end

  defp recently_broken?(_, _), do: false

  defp entry_for_already_held?(%{action: :enter, asset: a, pair_asset: b, direction: dir})
       when is_binary(a) and is_binary(b) do
    # Pair already open (order-insensitive) → skip.
    # Or the actual LONG LEG (the only side that gets bought in long-only
    # mode) already has any open position → skip. Multiple pair signals
    # (e.g. LINK↔UNI long_a, UNI/BTC↔LINK long_b) all buy the same long
    # leg — without this check the bot buys LINK 3× per scan cycle.
    long_leg =
      case dir do
        :long_a_short_b -> a
        :long_b_short_a -> b
        _ -> a
      end

    PairPositionStore.find_open_for_pair(a, b) != nil or
      PairPositionStore.find_open_for_asset(long_leg) != nil or
      recently_broken?(a, b) or
      recently_closed_asset?(long_leg) or
      not pair_cointegration_valid?(a, b)
  end

  defp entry_for_already_held?(%{action: :enter, asset: a}) when is_binary(a) do
    PairPositionStore.find_open_for_asset(a) != nil
  end

  defp entry_for_already_held?(_), do: false

  # Track consecutive nil-z reads per position (in-process ETS).
  # Reset on any successful read; increment on nil.
  @nil_z_table :engine_nil_z_streak

  defp ensure_nil_z_table, do: @nil_z_table

  defp consecutive_nil_z(pos) do
    ensure_nil_z_table()

    case :ets.lookup(@nil_z_table, pos.id) do
      [{_, n}] -> n
      _ -> 0
    end
  end

  defp record_z_observation(pos, nil) do
    ensure_nil_z_table()

    :ets.update_counter(@nil_z_table, pos.id, {2, 1}, {pos.id, 0})
  end

  defp record_z_observation(pos, _result) do
    ensure_nil_z_table()
    :ets.delete(@nil_z_table, pos.id)
    :ok
  end

  # Cointegration sanity check at ENTRY time. Two checks:
  # 1. recompute_z_score must succeed RIGHT NOW.
  # 2. Both legs must have at least @min_entry_bars recent closes — without
  #    enough history, the pair often computes a z that's noise, then
  #    becomes uncomputable on the next scan (PAIR BROKEN churn).
  @min_entry_bars 15

  defp pair_cointegration_valid?(a, b) when is_binary(a) and is_binary(b) do
    with {:ok, ca} <- get_best_closes(a),
         {:ok, cb} <- get_best_closes(b),
         true <- length(ca) >= @min_entry_bars and length(cb) >= @min_entry_bars,
         result when not is_nil(result) <- recompute_z_score(a, b) do
      true
    else
      _ ->
        mark_broken_pair(a, b)
        false
    end
  end

  defp pair_cointegration_valid?(_, _), do: true

  # Within-batch long-leg dedup. Keeps the highest-|z|-score entry per
  # long leg + non-:enter actions untouched.
  defp dedup_by_long_leg(hits) do
    {entries, others} = Enum.split_with(hits, &(&1.action == :enter))

    deduped =
      entries
      |> Enum.group_by(&long_leg_for/1)
      |> Enum.map(fn
        {nil, [first | _]} ->
          first

        {_long_leg, group} ->
          Enum.max_by(group, &entry_priority/1)
      end)
      |> Enum.flat_map(fn arb -> [arb] end)

    others ++ deduped
  end

  defp long_leg_for(%{asset: a, pair_asset: b, direction: :long_a_short_b})
       when is_binary(a) and is_binary(b),
       do: a

  defp long_leg_for(%{asset: a, pair_asset: b, direction: :long_b_short_a})
       when is_binary(a) and is_binary(b),
       do: b

  defp long_leg_for(%{asset: a}) when is_binary(a), do: a
  defp long_leg_for(_), do: nil

  defp discover_new_pairs do
    scanner_hits =
      try do
        case AlpacaTrader.Arbitrage.DiscoveryScanner.discover() do
          {signals, _count} when signals != [] ->
            Enum.map(signals, &signal_to_arb/1)

          _ ->
            []
        end
      catch
        :exit, _ -> []
      end

    # Also check dynamically built pairs from PairBuilder
    dynamic_hits =
      try do
        AlpacaTrader.Arbitrage.PairBuilder.dynamic_pairs()
        |> Enum.filter(fn p ->
          p.z_score != nil and abs(p.z_score) > 2.0 and
            PairPositionStore.find_open_for_asset(p.asset_a) == nil
        end)
        |> Enum.map(fn p ->
          direction = if p.z_score > 0, do: :long_b_short_a, else: :long_a_short_b

          %ArbitragePosition{
            result: true,
            asset: p.asset_a,
            reason: "DYNAMIC PAIR: r=#{p.correlation} z=#{p.z_score} (#{p.asset_a}↔#{p.asset_b})",
            action: :enter,
            tier: 2,
            pair_asset: p.asset_b,
            direction: direction,
            hedge_ratio: nil,
            z_score: p.z_score,
            spread: p.z_score,
            timestamp: DateTime.utc_now()
          }
        end)
      catch
        :exit, _ -> []
      end

    # Polymarket probability shift signals (Tier 4)
    polymarket_hits =
      try do
        AlpacaTrader.Polymarket.SignalGenerator.signals()
        |> Enum.filter(fn sig ->
          PairPositionStore.find_open_for_asset(sig.asset) == nil
        end)
      catch
        :exit, _ -> []
      end

    # Alternative data signals (Tier 5)
    alt_data_hits =
      try do
        entry_threshold = Application.get_env(:alpaca_trader, :alt_data_entry_threshold, 0.65)

        AlpacaTrader.AltData.SignalStore.all_active()
        |> Enum.filter(fn sig ->
          sig.strength >= entry_threshold and sig.direction in [:bullish, :risk_on]
        end)
        |> Enum.flat_map(fn sig ->
          Enum.flat_map(sig.affected_symbols || [], fn symbol ->
            if PairPositionStore.find_open_for_asset(symbol) == nil do
              [
                %ArbitragePosition{
                  result: true,
                  asset: symbol,
                  reason: "ALT_DATA[#{sig.provider}]: #{sig.reason}",
                  action: :enter,
                  tier: 5,
                  pair_asset: nil,
                  direction: nil,
                  hedge_ratio: nil,
                  z_score: nil,
                  spread: sig.strength,
                  timestamp: DateTime.utc_now()
                }
              ]
            else
              []
            end
          end)
        end)
      catch
        :exit, _ -> []
      end

    scanner_hits ++ dynamic_hits ++ polymarket_hits ++ alt_data_hits
  end

  defp signal_to_arb(sig) do
    %ArbitragePosition{
      result: true,
      asset: sig.asset_a,
      reason: "DISCOVERED: z=#{sig.z_score} (#{sig.asset_a}↔#{sig.asset_b})",
      action: :enter,
      tier: 2,
      pair_asset: sig.asset_b,
      direction: sig.direction,
      hedge_ratio: sig.hedge_ratio,
      z_score: sig.z_score,
      spread: sig.z_score,
      timestamp: DateTime.utc_now()
    }
  end

  # ── SHADOW LOGGER HELPERS ──────────────────────────────────
  # Additive, flag-gated. When :shadow_mode_enabled is false (the default),
  # these are zero-work no-ops.

  defp shadow_record(signal) do
    if Application.get_env(:alpaca_trader, :shadow_mode_enabled, false) do
      AlpacaTrader.ShadowLogger.record_signal(signal)
    end

    :ok
  end

  defp shadow_record_blocked(arb, gate_rejections) do
    shadow_record(%{
      timestamp: DateTime.utc_now(),
      pair: shadow_pair(arb),
      event: :entry_signal,
      status: :blocked,
      z_score: shadow_z(arb),
      gate_rejections: gate_rejections
    })
  end

  defp shadow_record_entry_result(arb, trades) do
    status =
      if Enum.any?(trades, &(&1.action in [:bought, :sold])),
        do: :filled,
        else: :rejected

    shadow_record(%{
      timestamp: DateTime.utc_now(),
      pair: shadow_pair(arb),
      event: :entry_signal,
      status: status,
      z_score: shadow_z(arb)
    })
  end

  defp shadow_pair(%ArbitragePosition{asset: a, pair_asset: b})
       when is_binary(a) and is_binary(b),
       do: "#{a}-#{b}"

  defp shadow_pair(%ArbitragePosition{asset: a}) when is_binary(a), do: a
  defp shadow_pair(_), do: "unknown"

  defp shadow_z(%ArbitragePosition{z_score: z}) when is_number(z), do: z * 1.0
  defp shadow_z(_), do: 0.0
end
