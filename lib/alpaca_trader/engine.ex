defmodule AlpacaTrader.Engine do
  @moduledoc """
  Single entry point for all trade decisions.
  """

  require Logger

  alias AlpacaTrader.Arbitrage.{BellmanFord, SubstituteDetector, ComplementDetector, AssetRelationships, RotationEvaluator}
  alias AlpacaTrader.Arbitrage.SpreadCalculator
  alias AlpacaTrader.{BarsStore, PairPositionStore}

  defmodule MarketContext do
    @derive Jason.Encoder
    defstruct [:symbol, :account, :position, :clock, :asset, :bars, :positions, :orders, :quotes, :prices]
  end

  defmodule PurchaseContext do
    @derive Jason.Encoder
    defstruct [:action, :symbol, :reason, :qty, :side, :order, :timestamp]
  end

  defmodule ArbitragePosition do
    @derive Jason.Encoder
    defstruct [
      :result, :asset, :reason, :related_positions, :spread, :timestamp,
      :tier, :pair_asset, :direction, :hedge_ratio, :z_score,
      :action, :replaces
    ]
  end

  defmodule ArbitrageScanResult do
    @derive Jason.Encoder
    defstruct [:scanned, :hits, :opportunities, :executed, :trades, :timestamp]
  end

  # ── execute_trade ──────────────────────────────────────────

  def execute_trade(%MarketContext{} = ctx, %{"side" => side} = params)
      when side in ["buy", "sell"] do
    asset_class      = get_in(ctx.asset, ["class"]) || "us_equity"
    market_open?     = get_in(ctx.clock, ["is_open"]) == true
    tradable?        = get_in(ctx.asset, ["tradable"]) == true
    fractionable?    = get_in(ctx.asset, ["fractionable"]) != false
    shorting_enabled? = get_in(ctx.account, ["shorting_enabled"]) == true
    buying_power     = parse_float(get_in(ctx.account, ["buying_power"]))
    equity           = parse_float(get_in(ctx.account, ["equity"]))
    notional         = params["notional"] && parse_float(params["notional"])
    reserve_pct      = Application.get_env(:alpaca_trader, :portfolio_reserve_pct, 0.25)
    reserve          = equity && equity * reserve_pct

    held_qty =
      (ctx.positions || [])
      |> Enum.find(fn p -> p["symbol"] == ctx.symbol end)
      |> case do
        %{"qty" => q} -> parse_float(q)
        _ -> 0.0
      end

    cond do
      not tradable? ->
        hold(ctx.symbol, "asset is not tradable")

      asset_class != "crypto" and not market_open? ->
        hold(ctx.symbol, "market is closed")

      side == "sell" and held_qty <= 0 and not shorting_enabled? ->
        hold(ctx.symbol, "account does not support shorting")

side == "buy" and notional != nil and buying_power != nil and reserve != nil and
          (buying_power - notional) < reserve ->
        hold(ctx.symbol, "portfolio reserve: $#{Float.round(buying_power - notional, 2)} remaining < $#{Float.round(reserve, 2)} (#{trunc(reserve_pct * 100)}% of $#{Float.round(equity, 2)})")

      side == "buy" and notional != nil and not fractionable? ->
        hold(ctx.symbol, "asset not fractionable, skipping notional order")

      true ->
        order_params = %{
          symbol: ctx.symbol,
          side: side,
          type: params["type"] || "market",
          time_in_force: params["time_in_force"] || if(asset_class == "crypto", do: "gtc", else: "day")
        }

        order_params = cond do
          params["notional"] -> Map.put(order_params, :notional, params["notional"])
          params["qty"]      -> Map.put(order_params, :qty, params["qty"])
          true               -> Map.put(order_params, :qty, "1")
        end

        order_params = order_params
        |> maybe_put(:limit_price, params["limit_price"])
        |> maybe_put(:stop_price, params["stop_price"])

        case AlpacaTrader.Alpaca.Client.create_order(order_params) do
          {:ok, order} ->
            action  = if(side == "buy", do: :bought, else: :sold)
            emoji   = if side == "buy", do: "🟢", else: "🔴"
            qty_str = if params["notional"], do: "$#{params["notional"]}", else: "qty=#{params["qty"]}"
            Logger.info("[Trade] #{emoji} #{String.upcase(side)} #{ctx.symbol} #{qty_str} status=#{order["status"]}")
            {:ok,
             %PurchaseContext{
               action: action,
               symbol: ctx.symbol,
               reason: "order #{order["status"]}",
               qty: params["qty"] || params["notional"], side: side, order: order,
               timestamp: DateTime.utc_now()
             }}

          {:error, err} ->
            Logger.warning("[Trade] ⚠️  ORDER REJECTED #{ctx.symbol} side=#{side}: #{inspect(err) |> String.slice(0..80)}")
            hold(ctx.symbol, "order rejected: #{inspect(err)}")
        end
    end
  end

  def execute_trade(%MarketContext{} = ctx, _params) do
    hold(ctx.symbol, "invalid params — side must be buy or sell, qty required")
  end

  defp hold(symbol, reason) do
    Logger.debug("[Trade] ⏸ HOLD #{symbol}: #{reason}")
    {:ok, %PurchaseContext{action: :hold, symbol: symbol, reason: reason, timestamp: DateTime.utc_now()}}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

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
        check_exit_conditions(ctx, pos, asset, related)

      nil ->
        check_entry_conditions(ctx, asset, related)
    end
  end

  # ── EXIT CONDITIONS ────────────────────────────────────────

  defp check_exit_conditions(ctx, pos, asset, related) do
    current = recompute_z_score(pos.asset_a, pos.asset_b)

    # Get current prices for P&L — live quotes first, then bars fallback
    price_a = get_live_price(ctx, pos.asset_a)
    price_b = get_live_price(ctx, pos.asset_b)
    pnl = compute_pnl(pos, price_a, price_b)

    # Tier-specific thresholds
    params = AssetRelationships.params_for(asset)
    profit_target = params.profit_target
    cut_loss = params.stop_loss

    # Update tracking
    z = if current, do: current.z_score, else: pos.current_z_score
    PairPositionStore.tick(pos.id, z)

    # Compute trend strength for flip gate
    spread_series = recompute_spread_series(pos.asset_a, pos.asset_b)
    trend = if spread_series, do: SpreadCalculator.trend_strength(spread_series), else: 0.0

    # Did z-score cross to opposite side? (flip candidate)
    z_crossed = current != nil and pos.entry_z_score != nil and
      ((pos.entry_z_score > 0 and current.z_score < -1.5) or
       (pos.entry_z_score < 0 and current.z_score > 1.5))

    can_flip = z_crossed and trend > 25 and PairPositionStore.can_flip?(pos.id)

    cond do
      # 1. PROFIT TARGET: spread moved in our favor → SELL
      pnl != nil and pnl.profit_pct >= profit_target ->
        exit_signal(asset, related, pos,
          "TAKE PROFIT: #{Float.round(pnl.profit_pct, 2)}% gain ($#{Float.round(pnl.dollar_pnl, 2)}) [target: #{profit_target}%]")

      # 2. FLIP: z-score crossed to opposite side + trending → reverse position
      can_flip ->
        flip_signal(asset, related, pos, current.z_score, trend, pnl)

      # 3. STOP LOSS: z-score diverged further
      current != nil and abs(current.z_score) >= pos.stop_z_threshold ->
        exit_signal(asset, related, pos,
          "STOP LOSS: z=#{current.z_score} exceeded #{pos.stop_z_threshold}")

      # 4. CUT LOSS: P&L below tier-specific threshold
      pnl != nil and pnl.profit_pct <= cut_loss ->
        # If trending, flip instead of just cutting
        if trend > 25 and PairPositionStore.can_flip?(pos.id) do
          flip_signal(asset, related, pos, z, trend, pnl)
        else
          exit_signal(asset, related, pos,
            "CUT LOSS: #{Float.round(pnl.profit_pct, 2)}% loss ($#{Float.round(pnl.dollar_pnl, 2)}) [limit: #{cut_loss}%]")
        end

      # 5. TIME EXIT: held too long
      pos.bars_held >= pos.max_hold_bars ->
        exit_signal(asset, related, pos,
          "TIME EXIT: held #{pos.bars_held} bars, P&L=#{format_pnl(pnl)}")

      # 6. COINTEGRATION BROKEN: can't compute z-score anymore
      current == nil ->
        exit_signal(asset, related, pos,
          "PAIR BROKEN: cannot compute spread, P&L=#{format_pnl(pnl)}")

      # 7. Z-SCORE REVERSION: spread reverted to mean
      abs(current.z_score) <= pos.exit_z_threshold ->
        exit_signal(asset, related, pos,
          "Z-REVERSION: z=#{current.z_score}, P&L=#{format_pnl(pnl)}")

      # 7. HOLD: still waiting
      true ->
        {:ok,
         %ArbitragePosition{
           result: false,
           asset: asset,
           reason: "HOLD: z=#{z}, P&L=#{format_pnl(pnl)} (#{pos.bars_held}/#{pos.max_hold_bars} bars)",
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
      dollar_pnl = (long_current - long_entry) + (short_entry - short_current)

      %{profit_pct: profit_pct, dollar_pnl: dollar_pnl,
        long_pnl: long_pnl, short_pnl: short_pnl}
    else
      nil
    end
  end

  # Live price: check snapshot quotes first (real-time), then bars (daily)
  defp get_live_price(%MarketContext{quotes: quotes}, symbol) when is_map(quotes) do
    case quotes do
      %{^symbol => %{"latestTrade" => %{"p" => price}}} when is_number(price) -> price
      %{^symbol => %{"latestQuote" => %{"ap" => ask, "bp" => bid}}} when is_number(ask) and is_number(bid) -> (ask + bid) / 2
      _ -> get_bars_price(symbol)
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
       reason: "FLIP: z=#{current_z} crossed (trend=#{trend}), P&L=#{format_pnl(pnl)}, flip##{pos.flip_count + 1}",
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
                   result: false, asset: asset, action: :hold,
                   reason: "no opportunity across all tiers",
                   related_positions: related, tier: nil,
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
        Logger.info("[Rotation] 🔄 #{arb.asset} (z=#{arb.z_score}) displaces #{victim.asset_a}↔#{victim.asset_b} (stale)")
        {:ok, %ArbitragePosition{arb | related_positions: related, action: :rotate, replaces: victim.id}}

      :enter_normally ->
        {:ok, %ArbitragePosition{arb | related_positions: related, action: :enter}}

      :skip ->
        {:ok, %{arb | related_positions: related, action: :hold,
          result: false, reason: "signal weaker than all open positions (rotation skip)"}}
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
               result: true, asset: asset, tier: 1, spread: profit,
               reason: "cycle: #{Enum.join(cycle, " → ")} (#{profit}%)",
               timestamp: DateTime.utc_now()
             }}

          nil -> :miss
        end

      _ -> :miss
    end
  end

  defp try_tier_2(asset) do
    case SubstituteDetector.detect(asset) do
      {:ok, %{z_score: z, hedge_ratio: ratio, asset_b: pair, direction: dir}} ->
        {:hit,
         %ArbitragePosition{
           result: true, asset: asset, tier: 2, spread: z,
           reason: "substitute spread z=#{z} (#{asset}↔#{pair})",
           pair_asset: pair, direction: dir, hedge_ratio: ratio, z_score: z,
           timestamp: DateTime.utc_now()
         }}

      {:ok, nil} -> :miss
    end
  end

  defp try_tier_3(asset) do
    case ComplementDetector.detect(asset) do
      {:ok, %{z_score: z, hedge_ratio: ratio, asset_b: pair, direction: dir}} ->
        {:hit,
         %ArbitragePosition{
           result: true, asset: asset, tier: 3, spread: z,
           reason: "complement spread z=#{z} (#{asset}↔#{pair})",
           pair_asset: pair, direction: dir, hedge_ratio: ratio, z_score: z,
           timestamp: DateTime.utc_now()
         }}

      {:ok, nil} -> :miss
    end
  end

  # ── scan_arbitrage / scan_and_execute ──────────────────────

  def scan_arbitrage(%MarketContext{} = ctx) do
    {scanned, hits} = do_scan(ctx)

    {:ok,
     %ArbitrageScanResult{
       scanned: scanned, hits: length(hits), opportunities: hits,
       executed: 0, trades: [], timestamp: DateTime.utc_now()
     }}
  end

  def scan_and_execute(%MarketContext{} = ctx) do
    # Reap stale positions first to free buying power before scanning
    reaped = reap_stale_positions(ctx)

    {scanned, hits} = do_scan(ctx)

    trades =
      Enum.flat_map(hits, fn arb ->
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
       scanned: scanned, hits: length(hits), opportunities: hits,
       executed: executed, trades: trades ++ reaped, timestamp: DateTime.utc_now()
     }}
  end

  # ── STALE POSITION REAPER ────────────────────────────────────
  # Close Alpaca positions that have negative unrealized P&L and have been
  # held long enough that they're just tying up buying power.
  # Caches PDT-rejected symbols so we don't retry every scan cycle.

  @pdt_cache_key :reaper_pdt_blocked
  @pdt_cache_ttl_s 3600  # retry PDT-blocked symbols after 1 hour

  defp reap_stale_positions(%MarketContext{} = ctx) do
    positions = ctx.positions || []
    market_open? = get_in(ctx.clock, ["is_open"]) == true
    pdt_blocked = get_pdt_blocked()

    positions
    |> Enum.filter(fn pos ->
      symbol = pos["symbol"]
      not Map.has_key?(pdt_blocked, symbol) and stale_position?(pos, market_open?)
    end)
    |> Enum.flat_map(fn pos ->
      symbol = pos["symbol"]
      unrealized = parse_float(pos["unrealized_pl"]) || 0.0
      pct = parse_float(pos["unrealized_plpc"]) || 0.0

      Logger.info(
        "[Reaper] 🪓 closing stale #{symbol}: " <>
          "P&L=$#{Float.round(unrealized, 2)} (#{Float.round(pct * 100, 2)}%)"
      )

      case AlpacaTrader.Alpaca.Client.close_position(URI.encode(symbol)) do
        {:ok, order} ->
          Logger.info("[Reaper] ✅ closed #{symbol} status=#{order["status"]}")

          # Also close the internal pair position if one exists
          case PairPositionStore.find_open_for_asset(symbol) do
            %PairPositionStore.PairPosition{id: id} -> PairPositionStore.close_position(id)
            _ -> :ok
          end

          [%PurchaseContext{
            action: :sold, symbol: symbol,
            reason: "stale position reaped: P&L=$#{Float.round(unrealized, 2)}",
            qty: pos["qty"], side: "sell", order: order,
            timestamp: DateTime.utc_now()
          }]

        {:error, %{"code" => 40310100} = _err} ->
          # PDT protection — cache this symbol so we don't retry every cycle
          mark_pdt_blocked(symbol)
          Logger.debug("[Reaper] 🔒 #{symbol} PDT-blocked, skipping for #{div(@pdt_cache_ttl_s, 60)} min")
          []

        {:error, err} ->
          Logger.warning("[Reaper] ⚠️ failed to close #{symbol}: #{inspect(err) |> String.slice(0..80)}")
          []
      end
    end)
  end

  defp get_pdt_blocked do
    now = System.system_time(:second)
    case :persistent_term.get(@pdt_cache_key, nil) do
      nil -> %{}
      cache ->
        # Evict expired entries
        cache
        |> Enum.reject(fn {_sym, ts} -> now - ts > @pdt_cache_ttl_s end)
        |> Map.new()
    end
  end

  defp mark_pdt_blocked(symbol) do
    cache = get_pdt_blocked()
    :persistent_term.put(@pdt_cache_key, Map.put(cache, symbol, System.system_time(:second)))
  end

  defp stale_position?(pos, market_open?) do
    asset_class = pos["asset_class"] || "us_equity"
    unrealized = parse_float(pos["unrealized_pl"]) || 0.0
    pct = parse_float(pos["unrealized_plpc"]) || 0.0
    market_value = parse_float(pos["market_value"]) || 0.0

    # Skip tiny/zero positions
    if abs(market_value) < 0.50 do
      false
    else
      is_crypto = asset_class == "crypto"

      # Crypto can be closed anytime; equities only when market is open
      can_close = is_crypto or market_open?

      # Stale = losing money (negative P&L) or flat with negligible gain
      losing = unrealized < 0 and pct < -0.005

      can_close and losing
    end
  end

  # ── PRE-FLIGHT: cheap checks before expensive LLM call ──────

  defp can_afford_entry?(ctx) do
    buying_power = parse_float(get_in(ctx.account, ["buying_power"])) || 0.0
    equity = parse_float(get_in(ctx.account, ["equity"])) || 0.0
    reserve_pct = Application.get_env(:alpaca_trader, :portfolio_reserve_pct, 0.25)
    notional_pct = Application.get_env(:alpaca_trader, :order_notional_pct, 0.001)
    reserve = equity * reserve_pct
    notional = max(equity * notional_pct, 1.0)

    (buying_power - notional) >= reserve
  end

  # ── LLM CONVICTION GATE ─────────────────────────────────────

  defp gate_and_enter(ctx, arb) do
    # Cheap checks first, expensive LLM last.
    # 1. Can the account afford a new entry? (buying power > reserve + notional)
    # 2. Is the gain accumulator allowing entries?
    # Only then call the LLM.
    cond do
      not can_afford_entry?(ctx) ->
        Logger.debug("[Pre-flight] ⏸ skipping #{arb.asset}: insufficient buying power for entry")
        []

      not gain_allows_entry?(ctx) ->
        []

      true ->
        case AlpacaTrader.LLM.OpinionGate.evaluate(arb, ctx) do
          {:ok, %{decision: "suppress"}} ->
            Logger.info("[LLM Gate] SUPPRESSED #{arb.asset}: #{arb.reason}")
            []

          {:ok, %{conviction: c}} when c < 0.3 ->
            Logger.info("[LLM Gate] LOW CONVICTION #{Float.round(c, 2)} for #{arb.asset}")
            []

          {:ok, %{conviction: c, reasoning: r}} ->
            Logger.info("[LLM Gate] CONFIRMED #{arb.asset} conviction=#{Float.round(c, 2)}: #{r}")
            execute_entry(ctx, arb)

          _ ->
            execute_entry(ctx, arb)
        end
    end
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
        Logger.info("[LLM Gate] CONFIRMED flip #{arb.asset} conviction=#{Float.round(c, 2)}: #{r}")
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
            Logger.info("[LLM Gate] LOW CONVICTION #{Float.round(c, 2)} for rotation #{arb.asset}")
            []

          {:ok, %{conviction: c, reasoning: r}} ->
            Logger.info("[LLM Gate] CONFIRMED rotation #{arb.asset} conviction=#{Float.round(c, 2)}: #{r}")
            execute_rotate(ctx, arb)

          _ ->
            execute_rotate(ctx, arb)
        end
    end
  end

  defp execute_rotate(ctx, arb) do
    # Step 1: Close the victim position (free the capital)
    victim = case :ets.lookup(:pair_position_store, arb.replaces) do
      [{_id, pos}] -> pos
      [] -> nil
    end

    exit_trades = if victim do
      victim_arb = %ArbitragePosition{
        result: true, asset: victim.asset_a, pair_asset: victim.asset_b,
        direction: victim.direction, tier: victim.tier, action: :exit,
        reason: "ROTATED OUT: replaced by #{arb.asset}↔#{arb.pair_asset} (z=#{arb.z_score})",
        z_score: victim.current_z_score, hedge_ratio: victim.entry_hedge_ratio,
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
    order_params = build_entry_params(ctx, arb)

    trades =
      case order_params do
        %{pair: true, legs: legs} ->
          Enum.map(legs, fn leg ->
            leg_ctx = build_leg_context(ctx, leg["symbol"])
            {:ok, purchase} = execute_trade(leg_ctx, leg)
            purchase
          end)

        params ->
          trade_ctx = build_leg_context(ctx, arb.asset)
          {:ok, purchase} = execute_trade(trade_ctx, params)
          [purchase]
      end

    # Track the position if any leg executed
    if arb.tier in [2, 3] and Enum.any?(trades, &(&1.action in [:bought, :sold])) do
      PairPositionStore.open_position(%{
        asset_a: arb.asset,
        asset_b: arb.pair_asset,
        direction: arb.direction,
        tier: arb.tier,
        z_score: arb.z_score,
        hedge_ratio: arb.hedge_ratio,
        entry_price_a: get_live_price(ctx, arb.asset),
        entry_price_b: get_live_price(ctx, arb.pair_asset)
      })
    end

    trades
  end

  # ── EXIT EXECUTION ─────────────────────────────────────────

  defp execute_exit(ctx, arb) do
    # Close the position: reverse the original direction
    exit_params = build_exit_params(ctx, arb)

    trades =
      case exit_params do
        %{pair: true, legs: legs} ->
          Enum.map(legs, fn leg ->
            leg_ctx = build_leg_context(ctx, leg["symbol"])
            {:ok, purchase} = execute_trade(leg_ctx, leg)
            purchase
          end)

        params ->
          trade_ctx = build_leg_context(ctx, arb.asset)
          {:ok, purchase} = execute_trade(trade_ctx, params)
          [purchase]
      end

    # Close the tracked position
    pos = PairPositionStore.find_open_for_asset(arb.asset)
    if pos, do: PairPositionStore.close_position(pos.id)

    trades
  end

  # ── FLIP EXECUTION: close old + open reversed ──────────────

  defp execute_flip(ctx, %ArbitragePosition{} = arb) do
    # Step 1: Close the current position (same as exit)
    exit_trades = execute_exit(ctx, arb)

    # Step 2: Open the reversed position
    reversed_arb = %ArbitragePosition{arb | direction: arb.direction, action: :enter}
    entry_trades = execute_entry(ctx, reversed_arb)

    # Step 3: Track the flip in PairPositionStore
    was_profitable =
      Enum.any?(exit_trades, fn t -> t.action in [:bought, :sold] end)

    case PairPositionStore.find_open_for_asset(arb.asset) do
      %PairPositionStore.PairPosition{} = pos ->
        :ets.insert(:pair_position_store, {
          pos.id,
          %PairPositionStore.PairPosition{
            pos |
            flip_count: pos.flip_count + 1,
            consecutive_losses: if(was_profitable, do: 0, else: pos.consecutive_losses + 1),
            last_flip_time: DateTime.utc_now()
          }
        })
      _ -> :ok
    end

    exit_trades ++ entry_trades
  end

  # ── ORDER PARAMS BUILDERS ──────────────────────────────────

  defp order_notional(ctx) do
    equity = parse_float(get_in(ctx.account, ["equity"])) || 0.0
    pct = Application.get_env(:alpaca_trader, :order_notional_pct, 0.001)
    notional = Float.round(equity * pct, 2)
    # Alpaca minimum notional is $1
    to_string(max(notional, 1.0))
  end

  defp build_entry_params(ctx, %ArbitragePosition{tier: 1} = arb) do
    %{"side" => if(arb.spread && arb.spread < 0, do: "sell", else: "buy"),
      "notional" => order_notional(ctx), "type" => "market"}
  end

  defp build_entry_params(ctx, %ArbitragePosition{tier: tier} = arb) when tier in [2, 3] do
    {long_sym, short_sym} =
      case arb.direction do
        :long_a_short_b -> {arb.asset, arb.pair_asset}
        :long_b_short_a -> {arb.pair_asset, arb.asset}
      end

    notional = order_notional(ctx)
    %{pair: true, legs: [
      %{"symbol" => long_sym, "side" => "buy", "notional" => notional, "type" => "market", "pair_leg" => true},
      %{"symbol" => short_sym, "side" => "sell", "notional" => notional, "type" => "market", "pair_leg" => true}
    ]}
  end

  defp build_entry_params(ctx, _arb), do: %{"side" => "buy", "notional" => order_notional(ctx), "type" => "market"}

  defp build_exit_params(ctx, %ArbitragePosition{tier: tier} = arb) when tier in [2, 3] do
    # Reverse the entry: sell what was bought, buy back what was shorted
    {sell_sym, buy_sym} =
      case arb.direction do
        :long_a_short_b -> {arb.asset, arb.pair_asset}
        :long_b_short_a -> {arb.pair_asset, arb.asset}
      end

    notional = order_notional(ctx)
    %{pair: true, legs: [
      %{"symbol" => sell_sym, "side" => "sell", "notional" => notional, "type" => "market", "pair_leg" => true},
      %{"symbol" => buy_sym, "side" => "buy", "notional" => notional, "type" => "market", "pair_leg" => true}
    ]}
  end

  defp build_exit_params(ctx, arb) do
    %{"side" => "sell", "notional" => order_notional(ctx), "type" => "market", "symbol" => arb.asset}
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
    crypto_syms = assets |> Enum.filter(& &1["class"] == "crypto") |> Enum.map(& &1["symbol"])
    AlpacaTrader.MinuteBarCache.refresh(crypto_syms)

    # Known asset scan (Tier 1/2/3 + exit checks)
    results =
      Enum.map(assets, fn asset ->
        {:ok, arb} = is_in_arbitrage_position(ctx, asset["symbol"])
        arb
      end)

    # Discovery scan: rotate through new stocks each iteration
    discovery_hits = discover_new_pairs()

    all_hits = Enum.filter(results, & &1.result) ++ discovery_hits
    {length(results) + length(discovery_hits), all_hits}
  end

  defp discover_new_pairs do
    scanner_hits = try do
      case AlpacaTrader.Arbitrage.DiscoveryScanner.discover() do
        {signals, _count} when signals != [] ->
          Enum.map(signals, &signal_to_arb/1)
        _ -> []
      end
    catch
      :exit, _ -> []
    end

    # Also check dynamically built pairs from PairBuilder
    dynamic_hits = try do
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
    polymarket_hits = try do
      AlpacaTrader.Polymarket.SignalGenerator.signals()
      |> Enum.filter(fn sig ->
        PairPositionStore.find_open_for_asset(sig.asset) == nil
      end)
    catch
      :exit, _ -> []
    end

    scanner_hits ++ dynamic_hits ++ polymarket_hits
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

  defp build_leg_context(%MarketContext{} = ctx, symbol) do
    asset_data =
      case AlpacaTrader.AssetStore.get(symbol) do
        {:ok, a} -> a
        :error -> %{"tradable" => true, "class" => "us_equity"}
      end

    %MarketContext{
      ctx
      | symbol: symbol,
        asset: asset_data,
        position: Enum.find(ctx.positions || [], fn p -> p["symbol"] == symbol end)
    }
  end
end
