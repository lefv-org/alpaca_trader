defmodule AlpacaTrader.Engine do
  @moduledoc """
  Single entry point for all trade decisions.
  """

  alias AlpacaTrader.Arbitrage.{BellmanFord, SubstituteDetector, ComplementDetector, AssetRelationships}
  alias AlpacaTrader.Arbitrage.SpreadCalculator
  alias AlpacaTrader.{BarsStore, PairPositionStore}

  defmodule MarketContext do
    @derive Jason.Encoder
    defstruct [:symbol, :account, :position, :clock, :asset, :bars, :positions, :orders, :quotes]
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
      :action
    ]
  end

  defmodule ArbitrageScanResult do
    @derive Jason.Encoder
    defstruct [:scanned, :hits, :opportunities, :executed, :trades, :timestamp]
  end

  # ── execute_trade ──────────────────────────────────────────

  def execute_trade(%MarketContext{} = ctx, %{"side" => side, "qty" => qty} = params)
      when side in ["buy", "sell"] do
    asset_class = get_in(ctx.asset, ["class"]) || "us_equity"
    market_open? = get_in(ctx.clock, ["is_open"]) == true
    tradable? = get_in(ctx.asset, ["tradable"]) == true

    cond do
      not tradable? ->
        hold(ctx.symbol, "asset is not tradable")

      asset_class != "crypto" and not market_open? ->
        hold(ctx.symbol, "market is closed")

      true ->
        order_params = %{
          symbol: ctx.symbol,
          qty: qty,
          side: side,
          type: params["type"] || "market",
          time_in_force: params["time_in_force"] || if(asset_class == "crypto", do: "gtc", else: "day")
        }
        |> maybe_put(:limit_price, params["limit_price"])
        |> maybe_put(:stop_price, params["stop_price"])

        case AlpacaTrader.Alpaca.Client.create_order(order_params) do
          {:ok, order} ->
            {:ok,
             %PurchaseContext{
               action: if(side == "buy", do: :bought, else: :sold),
               symbol: ctx.symbol,
               reason: "order #{order["status"]}",
               qty: qty, side: side, order: order,
               timestamp: DateTime.utc_now()
             }}

          {:error, err} ->
            hold(ctx.symbol, "order rejected: #{inspect(err)}")
        end
    end
  end

  def execute_trade(%MarketContext{} = ctx, _params) do
    hold(ctx.symbol, "invalid params — side must be buy or sell, qty required")
  end

  defp hold(symbol, reason) do
    {:ok, %PurchaseContext{action: :hold, symbol: symbol, reason: reason, timestamp: DateTime.utc_now()}}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

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
        check_exit_conditions(pos, asset, related)

      nil ->
        check_entry_conditions(ctx, asset, related)
    end
  end

  # ── EXIT CONDITIONS ────────────────────────────────────────

  defp check_exit_conditions(pos, asset, related) do
    current = recompute_z_score(pos.asset_a, pos.asset_b)

    # Update the position's current z-score and bar count
    if current do
      PairPositionStore.tick(pos.id, current.z_score)
    else
      PairPositionStore.tick(pos.id, pos.current_z_score)
    end

    cond do
      # 1. STOP LOSS: z-score diverged further
      current != nil and abs(current.z_score) >= pos.stop_z_threshold ->
        exit_signal(asset, related, pos,
          "STOP LOSS: z=#{current.z_score} exceeded #{pos.stop_z_threshold}")

      # 2. TIME EXIT: held too long
      pos.bars_held >= pos.max_hold_bars ->
        exit_signal(asset, related, pos,
          "TIME EXIT: held #{pos.bars_held} bars (max #{pos.max_hold_bars})")

      # 3. COINTEGRATION BROKEN: can't compute z-score anymore
      current == nil ->
        exit_signal(asset, related, pos,
          "PAIR BROKEN: cannot compute spread")

      # 4. TAKE PROFIT: z-score reverted toward mean
      abs(current.z_score) <= pos.exit_z_threshold ->
        exit_signal(asset, related, pos,
          "TAKE PROFIT: z=#{current.z_score} reverted below #{pos.exit_z_threshold}")

      # 5. HOLD: still waiting for reversion
      true ->
        {:ok,
         %ArbitragePosition{
           result: false,
           asset: asset,
           reason: "HOLD: z=#{current.z_score}, waiting (#{pos.bars_held}/#{pos.max_hold_bars} bars)",
           related_positions: related,
           action: :hold,
           tier: pos.tier,
           pair_asset: if(pos.asset_a == asset, do: pos.asset_b, else: pos.asset_a),
           z_score: current.z_score,
           timestamp: DateTime.utc_now()
         }}
    end
  end

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

  defp reverse_direction(:long_a_short_b), do: :long_b_short_a
  defp reverse_direction(:long_b_short_a), do: :long_a_short_b

  defp recompute_z_score(asset_a, asset_b) do
    with {:ok, closes_a} <- BarsStore.get_closes(asset_a),
         {:ok, closes_b} <- BarsStore.get_closes(asset_b) do
      len = min(length(closes_a), length(closes_b))
      a = Enum.take(closes_a, -len)
      b = Enum.take(closes_b, -len)
      SpreadCalculator.analyze(a, b)
    else
      _ -> nil
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
            {:ok, %ArbitragePosition{arb | related_positions: related, action: :enter}}

          :miss ->
            case try_tier_3(asset) do
              {:hit, arb} ->
                {:ok, %ArbitragePosition{arb | related_positions: related, action: :enter}}

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
    {scanned, hits} = do_scan(ctx)

    trades =
      Enum.flat_map(hits, fn arb ->
        case arb.action do
          :enter -> execute_entry(ctx, arb)
          :exit -> execute_exit(ctx, arb)
          _ -> []
        end
      end)

    executed = Enum.count(trades, &(&1.action in [:bought, :sold]))

    {:ok,
     %ArbitrageScanResult{
       scanned: scanned, hits: length(hits), opportunities: hits,
       executed: executed, trades: trades, timestamp: DateTime.utc_now()
     }}
  end

  # ── ENTRY EXECUTION ────────────────────────────────────────

  defp execute_entry(ctx, arb) do
    order_params = build_entry_params(arb)

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
        hedge_ratio: arb.hedge_ratio
      })
    end

    trades
  end

  # ── EXIT EXECUTION ─────────────────────────────────────────

  defp execute_exit(ctx, arb) do
    # Close the position: reverse the original direction
    exit_params = build_exit_params(arb)

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

  # ── ORDER PARAMS BUILDERS ──────────────────────────────────

  defp build_entry_params(%ArbitragePosition{tier: 1} = arb) do
    %{"side" => if(arb.spread && arb.spread < 0, do: "sell", else: "buy"),
      "qty" => "1", "type" => "market"}
  end

  defp build_entry_params(%ArbitragePosition{tier: tier} = arb) when tier in [2, 3] do
    {long_sym, short_sym} =
      case arb.direction do
        :long_a_short_b -> {arb.asset, arb.pair_asset}
        :long_b_short_a -> {arb.pair_asset, arb.asset}
      end

    %{pair: true, legs: [
      %{"symbol" => long_sym, "side" => "buy", "qty" => "1", "type" => "market"},
      %{"symbol" => short_sym, "side" => "sell", "qty" => "1", "type" => "market"}
    ]}
  end

  defp build_entry_params(_arb), do: %{"side" => "buy", "qty" => "1", "type" => "market"}

  defp build_exit_params(%ArbitragePosition{tier: tier} = arb) when tier in [2, 3] do
    # Reverse the entry: sell what was bought, buy back what was shorted
    {sell_sym, buy_sym} =
      case arb.direction do
        :long_a_short_b -> {arb.asset, arb.pair_asset}
        :long_b_short_a -> {arb.pair_asset, arb.asset}
      end

    %{pair: true, legs: [
      %{"symbol" => sell_sym, "side" => "sell", "qty" => "1", "type" => "market"},
      %{"symbol" => buy_sym, "side" => "buy", "qty" => "1", "type" => "market"}
    ]}
  end

  defp build_exit_params(arb) do
    %{"side" => "sell", "qty" => "1", "type" => "market", "symbol" => arb.asset}
  end

  # ── HELPERS ────────────────────────────────────────────────

  defp do_scan(ctx) do
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
        asset["class"] == "crypto" or asset["symbol"] in all_symbols
      end)

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
    case AlpacaTrader.Arbitrage.DiscoveryScanner.discover() do
      {signals, _count} when signals != [] ->
        Enum.map(signals, fn sig ->
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
        end)

      _ ->
        []
    end
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
