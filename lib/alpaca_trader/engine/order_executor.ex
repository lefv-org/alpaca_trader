defmodule AlpacaTrader.Engine.OrderExecutor do
  @moduledoc """
  Order-submission primitives: single-leg `execute_trade/2`, pair-leg dry-run
  validation via `preflight_leg/2`, and atomic pair submission via
  `execute_pair_atomic/4`.

  Lives as a separate module so the engine's high-level orchestration
  (`scan_and_execute`, entry/exit conditions, flips) can stay focused on the
  *decision* of what to trade while this module owns the *mechanics* of how
  the trade reaches Alpaca safely.

  Safety properties enforced here:
  - Every order carries a `client_order_id` for server-side dedup.
  - Pair legs are all-or-nothing: every leg must pass preflight before any
    leg submits an order.
  - Orphan positions (held on Alpaca but not tracked locally) block new
    entries on that symbol.
  """

  require Logger

  alias AlpacaTrader.Engine.{MarketContext, PurchaseContext}
  alias AlpacaTrader.PairPositionStore
  alias AlpacaTrader.PositionReconciler

  @doc """
  Construct an order payload given the desired fill mode. Pure — no API call.

  `mode`:
  - `:market` — legacy market order (`type: "market"`, `time_in_force: "day"`).
  - `:marketable_limit` — IOC limit order at `ask + k*spread` (buy) or
    `bid - k*spread` (sell). Filling against the opposite side of the book
    caps tail slippage while giving `SlippageMeasurement` a reference price.

  `quote` is a positional map containing `:bid` and `:ask` (numeric).

  Options:
  - `:mode` — `:market` (default) or `:marketable_limit`
  - `:spread_mult` — k, defaults to 0.25
  """
  def build_order(%{symbol: s, qty: q, side: side}, quote, opts \\ []) when is_map(quote) do
    mode = Keyword.get(opts, :mode, :market)
    spread_mult = Keyword.get(opts, :spread_mult, 0.25)

    case mode do
      :market ->
        %{symbol: s, qty: q, side: side, type: "market", time_in_force: "day"}

      :marketable_limit ->
        limit_price = marketable_limit_price_pure(side, quote.bid, quote.ask, spread_mult)

        %{
          symbol: s,
          qty: q,
          side: side,
          type: "limit",
          time_in_force: "ioc",
          limit_price: limit_price
        }
    end
  end

  defp marketable_limit_price_pure(side, bid, ask, k) when side in [:buy, "buy"],
    do: ask + k * (ask - bid)

  defp marketable_limit_price_pure(side, bid, ask, k) when side in [:sell, "sell"],
    do: bid - k * (ask - bid)

  @doc """
  Submit a single order for one symbol, with safety preflights (tradable,
  market open, PDT, shorting, buying power, fractionable).
  """
  def execute_trade(%MarketContext{} = ctx, %{"side" => side} = params)
      when side in ["buy", "sell"] do
    asset_class = get_in(ctx.asset, ["class"]) || "us_equity"
    market_open? = get_in(ctx.clock, ["is_open"]) == true
    tradable? = get_in(ctx.asset, ["tradable"]) == true
    fractionable? = get_in(ctx.asset, ["fractionable"]) != false
    shorting_enabled? = get_in(ctx.account, ["shorting_enabled"]) == true
    buying_power = parse_float(get_in(ctx.account, ["buying_power"]))
    notional = params["notional"] && parse_float(params["notional"])
    daytrade_count = parse_float(get_in(ctx.account, ["daytrade_count"])) || 0
    equity = parse_float(get_in(ctx.account, ["equity"])) || 0.0

    held_qty =
      (ctx.positions || [])
      |> Enum.find(fn p -> p["symbol"] == ctx.symbol end)
      |> case do
        %{"qty" => q} -> parse_float(q)
        _ -> 0.0
      end

    pdt_at_limit = asset_class != "crypto" and equity < 25_000 and daytrade_count >= 3
    pdt_would_block = pdt_at_limit and side == "sell" and opened_today?(ctx, ctx.symbol)

    cond do
      not tradable? ->
        hold(ctx.symbol, "asset is not tradable")

      asset_class != "crypto" and not market_open? ->
        hold(ctx.symbol, "market is closed")

      side == "sell" and pdt_would_block ->
        hold(
          ctx.symbol,
          "PDT limit (#{trunc(daytrade_count)}/3 day trades, equity < $25k, same-day position)"
        )

      side == "sell" and held_qty <= 0 and not shorting_enabled? ->
        hold(ctx.symbol, "account does not support shorting")

      side == "buy" and notional != nil and buying_power != nil and buying_power < notional ->
        hold(
          ctx.symbol,
          "insufficient buying power: $#{Float.round(buying_power, 2)} < $#{notional} needed"
        )

      side == "buy" and notional != nil and not fractionable? ->
        hold(ctx.symbol, "asset not fractionable, skipping notional order")

      true ->
        # Marketable-limit mode caps tail slippage. The limit is set far enough
        # from the market to fill ~always but rejects in pathological spreads.
        {order_type, maybe_limit_price} = resolve_order_type(ctx, params, side)

        tif_default = resolve_time_in_force(order_type, params, asset_class)

        order_params = %{
          symbol: ctx.symbol,
          side: side,
          type: order_type,
          time_in_force: tif_default
        }

        order_params = Map.merge(order_params, maybe_limit_price)

        order_params =
          cond do
            params["notional"] -> Map.put(order_params, :notional, params["notional"])
            params["qty"] -> Map.put(order_params, :qty, params["qty"])
            true -> Map.put(order_params, :qty, "1")
          end

        order_params =
          order_params
          |> maybe_put(:limit_price, params["limit_price"])
          |> maybe_put(:stop_price, params["stop_price"])
          |> Map.put_new(:client_order_id, params["client_order_id"] || new_client_order_id())

        case AlpacaTrader.Broker.impl(:alpaca).submit_order_raw(order_params) do
          {:ok, order} ->
            action = if(side == "buy", do: :bought, else: :sold)
            emoji = if side == "buy", do: "🟢", else: "🔴"

            qty_str =
              if params["notional"], do: "$#{params["notional"]}", else: "qty=#{params["qty"]}"

            Logger.info(
              "[Trade] #{emoji} #{String.upcase(side)} #{ctx.symbol} #{qty_str} status=#{order["status"]}"
            )

            # Structured fill metadata — SlippageMeasurement compares filled price
            # vs limit_price to quantify effective slippage on marketable-limit fills.
            Logger.info(
              "[OrderExecutor] submitted: " <>
                inspect(%{
                  mode: order_type,
                  side: side,
                  symbol: ctx.symbol,
                  limit_price: Map.get(order_params, :limit_price),
                  filled_avg_price: order["filled_avg_price"],
                  status: order["status"]
                })
            )

            {:ok,
             %PurchaseContext{
               action: action,
               symbol: ctx.symbol,
               reason: "order #{order["status"]}",
               qty: params["qty"] || params["notional"],
               side: side,
               order: order,
               timestamp: DateTime.utc_now()
             }}

          {:error, err} ->
            Logger.warning(
              "[Trade] ⚠️  ORDER REJECTED #{ctx.symbol} side=#{side}: #{inspect(err) |> String.slice(0..80)}"
            )

            hold(ctx.symbol, "order rejected: #{inspect(err)}")
        end
    end
  end

  def execute_trade(%MarketContext{} = ctx, _params) do
    hold(ctx.symbol, "invalid params — side must be buy or sell, qty required")
  end

  @doc """
  Atomic multi-leg submission. Preflights every leg; submits orders only if
  all legs pass. Used for pair trades (entry and exit) and flips.
  """
  def execute_pair_atomic(%MarketContext{} = ctx, legs, pair_label, phase)
      when phase in [:entry, :exit] do
    leg_contexts =
      Enum.map(legs, fn leg ->
        {build_leg_context(ctx, leg["symbol"]), leg}
      end)

    blockers =
      Enum.flat_map(leg_contexts, fn {leg_ctx, leg} ->
        case preflight_leg(leg_ctx, leg) do
          :ok -> []
          {:blocked, reason} -> [{leg["symbol"], leg["side"], reason}]
        end
      end)

    if blockers == [] do
      Enum.map(leg_contexts, fn {leg_ctx, leg} ->
        {:ok, purchase} = execute_trade(leg_ctx, leg)
        purchase
      end)
    else
      blocked_desc =
        Enum.map_join(blockers, ", ", fn {sym, side, reason} ->
          "#{sym}(#{side}): #{reason}"
        end)

      log_level = if phase == :exit, do: :warning, else: :debug
      Logger.log(log_level, "[Trade] ⏸ HOLD pair #{pair_label} (#{phase}): #{blocked_desc}")

      Enum.map(leg_contexts, fn {leg_ctx, _leg} ->
        %PurchaseContext{
          action: :hold,
          symbol: leg_ctx.symbol,
          reason: "pair leg blocked",
          timestamp: DateTime.utc_now()
        }
      end)
    end
  end

  @doc "True if any of the trades actually executed (not just held)."
  def pair_executed?(trades) do
    Enum.any?(trades, &(&1.action in [:bought, :sold]))
  end

  @doc "Specialize a market context for a specific leg symbol."
  def build_leg_context(%MarketContext{} = ctx, symbol) do
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

  # Dry-run validation: mirrors execute_trade's gating without submitting.
  @doc false
  def preflight_leg(%MarketContext{} = ctx, %{"side" => side} = params) do
    asset_class = get_in(ctx.asset, ["class"]) || "us_equity"
    market_open? = get_in(ctx.clock, ["is_open"]) == true
    tradable? = get_in(ctx.asset, ["tradable"]) == true
    fractionable? = get_in(ctx.asset, ["fractionable"]) != false
    shorting_enabled? = get_in(ctx.account, ["shorting_enabled"]) == true
    buying_power = parse_float(get_in(ctx.account, ["buying_power"]))
    notional = params["notional"] && parse_float(params["notional"])
    daytrade_count = parse_float(get_in(ctx.account, ["daytrade_count"])) || 0
    equity = parse_float(get_in(ctx.account, ["equity"])) || 0.0

    held_qty =
      (ctx.positions || [])
      |> Enum.find(fn p -> p["symbol"] == ctx.symbol end)
      |> case do
        %{"qty" => q} -> parse_float(q)
        _ -> 0.0
      end

    pdt_at_limit = asset_class != "crypto" and equity < 25_000 and daytrade_count >= 3
    pdt_would_block = pdt_at_limit and side == "sell" and opened_today?(ctx, ctx.symbol)

    cond do
      not tradable? ->
        {:blocked, "not tradable"}

      side == "buy" and PositionReconciler.orphan?(ctx.symbol) ->
        {:blocked, "orphan position on Alpaca not tracked locally"}

      asset_class != "crypto" and not market_open? ->
        {:blocked, "market closed"}

      side == "sell" and pdt_would_block ->
        {:blocked, "PDT limit (#{trunc(daytrade_count)}/3 day trades, same-day position)"}

      side == "sell" and held_qty <= 0 and not shorting_enabled? ->
        {:blocked, "no shorting"}

      side == "buy" and notional != nil and buying_power != nil and buying_power < notional ->
        {:blocked, "insufficient buying power"}

      side == "buy" and notional != nil and not fractionable? ->
        {:blocked, "not fractionable"}

      true ->
        :ok
    end
  end

  @doc false
  # Resolve the effective time_in_force for a resolved order.
  #
  # When the live path ended up with a "limit" order because :order_type_mode
  # is :marketable_limit (and the caller did not pass an explicit type), we
  # force IOC: fill immediately against the top of the book or cancel. A
  # resting day/gtc limit at mid ± 50bps would leak information and could be
  # picked off — not what the spec intends.
  #
  # Otherwise, respect params["time_in_force"], falling back to the asset-
  # class default ("gtc" for crypto, "day" for equities).
  def resolve_time_in_force(order_type, params, asset_class) do
    marketable_limit_mode? =
      Application.get_env(:alpaca_trader, :order_type_mode, :market) ==
        :marketable_limit

    cond do
      order_type == "limit" and marketable_limit_mode? and
          not is_binary(params["type"]) ->
        "ioc"

      true ->
        params["time_in_force"] ||
          if(asset_class == "crypto", do: "gtc", else: "day")
    end
  end

  # Choose order type based on config. :market is the historical default.
  # :marketable_limit wraps the market in a limit price ±N bps away, which
  # fills like a market in normal conditions but rejects during liquidity gaps.
  defp resolve_order_type(ctx, params, side) do
    # An explicit params["type"] always wins (caller knows better than us)
    case params["type"] do
      type when is_binary(type) and type != "market" ->
        maybe = if params["limit_price"], do: %{limit_price: params["limit_price"]}, else: %{}
        {type, maybe}

      _ ->
        case Application.get_env(:alpaca_trader, :order_type_mode, :market) do
          :marketable_limit ->
            case marketable_limit_price(ctx, side) do
              {:ok, price} -> {"limit", %{limit_price: to_string(price)}}
              :error -> {"market", %{}}
            end

          _ ->
            {"market", %{}}
        end
    end
  end

  defp marketable_limit_price(ctx, side) do
    symbol = ctx.symbol

    cond do
      is_map(ctx.quotes) && is_map(ctx.quotes[symbol]) ->
        quote_price_from(ctx.quotes[symbol], side)

      is_map(ctx.prices) && is_map(ctx.prices[symbol]) ->
        quote_price_from(ctx.prices[symbol], side)

      true ->
        :error
    end
  end

  defp quote_price_from(quote_map, side) do
    # Two-model strategy:
    #   1. When both bid (bp) AND ask (ap) are available, use the spread-fraction
    #      model: buy = ask + k*(ask-bid); sell = bid - k*(ask-bid). This matches
    #      `build_order/3` semantics and is driven by :marketable_limit_spread_mult.
    #   2. Otherwise (e.g., only latestTrade.p), fall back to the bps-tolerance
    #      model driven by :order_marketable_limit_tolerance_bps.
    latest_quote = quote_map["latestQuote"]

    bid = if is_map(latest_quote), do: latest_quote["bp"], else: nil
    ask = if is_map(latest_quote), do: latest_quote["ap"], else: nil

    cond do
      is_number(bid) and is_number(ask) and bid > 0 and ask > 0 and ask >= bid ->
        k =
          Application.get_env(:alpaca_trader, :marketable_limit_spread_mult, 0.25)

        spread = ask - bid

        price =
          case side do
            "buy" -> ask + k * spread
            "sell" -> bid - k * spread
          end

        if is_number(price) and price > 0,
          do: {:ok, Float.round(price * 1.0, 6)},
          else: :error

      true ->
        bps_fallback_price(quote_map, side)
    end
  end

  defp bps_fallback_price(quote_map, side) do
    tolerance_bps =
      Application.get_env(:alpaca_trader, :order_marketable_limit_tolerance_bps, 50)

    multiplier =
      case side do
        "buy" -> 1 + tolerance_bps / 10_000
        "sell" -> 1 - tolerance_bps / 10_000
      end

    price =
      cond do
        side == "buy" and is_map(quote_map["latestQuote"]) and
            is_number(quote_map["latestQuote"]["ap"]) ->
          quote_map["latestQuote"]["ap"]

        side == "sell" and is_map(quote_map["latestQuote"]) and
            is_number(quote_map["latestQuote"]["bp"]) ->
          quote_map["latestQuote"]["bp"]

        is_map(quote_map["latestTrade"]) and is_number(quote_map["latestTrade"]["p"]) ->
          quote_map["latestTrade"]["p"]

        true ->
          nil
      end

    if is_number(price) and price > 0,
      do: {:ok, Float.round(price * multiplier, 6)},
      else: :error
  end

  # ── Helpers ────────────────────────────────────────────────

  defp hold(symbol, reason) do
    Logger.debug("[Trade] ⏸ HOLD #{symbol}: #{reason}")

    {:ok,
     %PurchaseContext{
       action: :hold,
       symbol: symbol,
       reason: reason,
       timestamp: DateTime.utc_now()
     }}
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

  # Alpaca accepts client_order_id up to 48 chars. "at-" prefix tags orders
  # originating from this app for forensics in the Alpaca UI/API.
  defp new_client_order_id do
    "at-" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
  end

  # A position was opened today if we have a filled BUY order for this symbol
  # dated today. Falls back to PairPositionStore.entry_time for positions we
  # opened locally. Used by the PDT check to avoid blocking closes of
  # yesterday-opened positions.
  defp opened_today?(ctx, symbol) do
    today = Date.utc_today()

    same_day_fill? =
      (ctx.orders || [])
      |> Enum.any?(fn o ->
        o["symbol"] == symbol and
          o["status"] == "filled" and
          filled_on?(o["filled_at"], today)
      end)

    if same_day_fill? do
      true
    else
      case PairPositionStore.find_open_for_asset(symbol) do
        %PairPositionStore.PairPosition{entry_time: %DateTime{} = et} ->
          DateTime.to_date(et) == today

        _ ->
          false
      end
    end
  end

  defp filled_on?(nil, _today), do: false

  defp filled_on?(ts, today) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> DateTime.to_date(dt) == today
      _ -> false
    end
  end

  defp filled_on?(_, _), do: false
end
