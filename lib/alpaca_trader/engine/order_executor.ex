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
  Submit a single order for one symbol, with safety preflights (tradable,
  market open, PDT, shorting, buying power, fractionable).
  """
  def execute_trade(%MarketContext{} = ctx, %{"side" => side} = params)
      when side in ["buy", "sell"] do
    asset_class      = get_in(ctx.asset, ["class"]) || "us_equity"
    market_open?     = get_in(ctx.clock, ["is_open"]) == true
    tradable?        = get_in(ctx.asset, ["tradable"]) == true
    fractionable?    = get_in(ctx.asset, ["fractionable"]) != false
    shorting_enabled? = get_in(ctx.account, ["shorting_enabled"]) == true
    buying_power     = parse_float(get_in(ctx.account, ["buying_power"]))
    notional         = params["notional"] && parse_float(params["notional"])
    daytrade_count   = parse_float(get_in(ctx.account, ["daytrade_count"])) || 0
    equity           = parse_float(get_in(ctx.account, ["equity"])) || 0.0

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
        hold(ctx.symbol, "PDT limit (#{trunc(daytrade_count)}/3 day trades, equity < $25k, same-day position)")

      side == "sell" and held_qty <= 0 and not shorting_enabled? ->
        hold(ctx.symbol, "account does not support shorting")

      side == "buy" and notional != nil and buying_power != nil and buying_power < notional ->
        hold(ctx.symbol, "insufficient buying power: $#{Float.round(buying_power, 2)} < $#{notional} needed")

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
        |> Map.put_new(:client_order_id, params["client_order_id"] || new_client_order_id())

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

  @doc """
  Atomic multi-leg submission. Preflights every leg; submits orders only if
  all legs pass. Used for pair trades (entry and exit) and flips.
  """
  def execute_pair_atomic(%MarketContext{} = ctx, legs, pair_label, phase)
      when phase in [:entry, :exit] do
    leg_contexts = Enum.map(legs, fn leg ->
      {build_leg_context(ctx, leg["symbol"]), leg}
    end)

    blockers = Enum.flat_map(leg_contexts, fn {leg_ctx, leg} ->
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
      blocked_desc = Enum.map_join(blockers, ", ", fn {sym, side, reason} ->
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
    asset_class      = get_in(ctx.asset, ["class"]) || "us_equity"
    market_open?     = get_in(ctx.clock, ["is_open"]) == true
    tradable?        = get_in(ctx.asset, ["tradable"]) == true
    fractionable?    = get_in(ctx.asset, ["fractionable"]) != false
    shorting_enabled? = get_in(ctx.account, ["shorting_enabled"]) == true
    buying_power     = parse_float(get_in(ctx.account, ["buying_power"]))
    notional         = params["notional"] && parse_float(params["notional"])
    daytrade_count   = parse_float(get_in(ctx.account, ["daytrade_count"])) || 0
    equity           = parse_float(get_in(ctx.account, ["equity"])) || 0.0

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
      not tradable? -> {:blocked, "not tradable"}
      side == "buy" and PositionReconciler.orphan?(ctx.symbol) ->
        {:blocked, "orphan position on Alpaca not tracked locally"}
      asset_class != "crypto" and not market_open? -> {:blocked, "market closed"}
      side == "sell" and pdt_would_block -> {:blocked, "PDT limit (#{trunc(daytrade_count)}/3 day trades, same-day position)"}
      side == "sell" and held_qty <= 0 and not shorting_enabled? -> {:blocked, "no shorting"}
      side == "buy" and notional != nil and buying_power != nil and buying_power < notional ->
        {:blocked, "insufficient buying power"}
      side == "buy" and notional != nil and not fractionable? -> {:blocked, "not fractionable"}
      true -> :ok
    end
  end

  # ── Helpers ────────────────────────────────────────────────

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
