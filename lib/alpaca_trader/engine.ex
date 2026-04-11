defmodule AlpacaTrader.Engine do
  @moduledoc """
  Single entry point for all trade decisions.
  """

  alias AlpacaTrader.Arbitrage.{BellmanFord, SubstituteDetector, ComplementDetector, AssetRelationships}

  defmodule MarketContext do
    @moduledoc """
    Raw market data fed into execute_trade/2.
    """
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
      :quotes
    ]
  end

  defmodule PurchaseContext do
    @moduledoc """
    Result of execute_trade/2 — wraps trade confirmation.
    """
    @derive Jason.Encoder
    defstruct [
      :action,
      :symbol,
      :reason,
      :qty,
      :side,
      :order,
      :timestamp
    ]
  end

  defmodule ArbitragePosition do
    @moduledoc """
    Result of is_in_arbitrage_position/2 — describes whether an arbitrage
    opportunity exists for a given asset, across all detection tiers.
    """
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
      :z_score
    ]
  end

  defmodule ArbitrageScanResult do
    @moduledoc """
    Result of scan_arbitrage/1 or scan_and_execute/1.
    """
    @derive Jason.Encoder
    defstruct [
      :scanned,
      :hits,
      :opportunities,
      :executed,
      :trades,
      :timestamp
    ]
  end

  # ── execute_trade ──────────────────────────────────────────

  @doc """
  The single point in the app where buy/sell trades are executed.

  Takes a MarketContext and order params (%{side, qty, type, time_in_force}).
  Validates the trade, executes it via the Alpaca API, and returns a
  PurchaseContext with the order confirmation.
  """
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

        order_params =
          order_params
          |> maybe_put(:limit_price, params["limit_price"])
          |> maybe_put(:stop_price, params["stop_price"])

        case AlpacaTrader.Alpaca.Client.create_order(order_params) do
          {:ok, order} ->
            action = if side == "buy", do: :bought, else: :sold

            {:ok,
             %PurchaseContext{
               action: action,
               symbol: ctx.symbol,
               reason: "order #{order["status"]}",
               qty: qty,
               side: side,
               order: order,
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
    {:ok,
     %PurchaseContext{
       action: :hold,
       symbol: symbol,
       reason: reason,
       qty: nil,
       side: nil,
       order: nil,
       timestamp: DateTime.utc_now()
     }}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  # ── is_in_arbitrage_position (3-tier cascade) ─────────────

  @doc """
  The sole decision point for whether to trade.

  Cascades through three detection tiers:
    Tier 1: Direct arbitrage (Bellman-Ford crypto cycles)
    Tier 2: Substitute pair arbitrage (z-score on cointegrated spread)
    Tier 3: Complement pair arbitrage (z-score, higher threshold)
  """
  def is_in_arbitrage_position(%MarketContext{} = ctx, asset) do
    related =
      (ctx.positions || [])
      |> Enum.filter(fn p -> String.contains?(p["symbol"], asset) end)

    case try_tier_1(ctx, asset) do
      {:hit, arb} ->
        {:ok, %ArbitragePosition{arb | related_positions: related}}

      :miss ->
        case try_tier_2(asset) do
          {:hit, arb} ->
            {:ok, %ArbitragePosition{arb | related_positions: related}}

          :miss ->
            case try_tier_3(asset) do
              {:hit, arb} ->
                {:ok, %ArbitragePosition{arb | related_positions: related}}

              :miss ->
                {:ok,
                 %ArbitragePosition{
                   result: false,
                   asset: asset,
                   reason: "no opportunity across all tiers",
                   related_positions: related,
                   tier: nil,
                   timestamp: DateTime.utc_now()
                 }}
            end
        end
    end
  end

  # Tier 1: Bellman-Ford crypto cycle detection
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
               reason: "cycle: #{Enum.join(cycle, " → ")} (#{profit}%)",
               spread: profit,
               tier: 1,
               timestamp: DateTime.utc_now()
             }}

          nil ->
            :miss
        end

      _ ->
        :miss
    end
  end

  # Tier 2: Substitute pair z-score
  defp try_tier_2(asset) do
    case SubstituteDetector.detect(asset) do
      {:ok, %{z_score: z, hedge_ratio: ratio, asset_b: pair, direction: dir}} ->
        {:hit,
         %ArbitragePosition{
           result: true,
           asset: asset,
           reason: "substitute spread z=#{z} (#{asset}↔#{pair})",
           spread: z,
           tier: 2,
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

  # Tier 3: Complement pair z-score
  defp try_tier_3(asset) do
    case ComplementDetector.detect(asset) do
      {:ok, %{z_score: z, hedge_ratio: ratio, asset_b: pair, direction: dir}} ->
        {:hit,
         %ArbitragePosition{
           result: true,
           asset: asset,
           reason: "complement spread z=#{z} (#{asset}↔#{pair})",
           spread: z,
           tier: 3,
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

  @doc """
  Scans assets for arbitrage opportunities (dry run — no trades).
  """
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

  @doc """
  Full pipeline: scan → detect → execute.
  Called by the ArbitrageScanJob cron every minute.
  """
  def scan_and_execute(%MarketContext{} = ctx) do
    {scanned, hits} = do_scan(ctx)

    trades =
      Enum.flat_map(hits, fn arb ->
        order_params = build_order_params(arb)
        execute_arb_trade(ctx, arb, order_params)
      end)

    executed = Enum.count(trades, &(&1.action in [:bought, :sold]))

    {:ok,
     %ArbitrageScanResult{
       scanned: scanned,
       hits: length(hits),
       opportunities: hits,
       executed: executed,
       trades: trades,
       timestamp: DateTime.utc_now()
     }}
  end

  # Only scan assets that matter: crypto (Tier 1) + relationship-connected (Tier 2/3)
  defp do_scan(ctx) do
    relationship_symbols = AssetRelationships.all_symbols() |> MapSet.new()

    assets =
      AlpacaTrader.AssetStore.all()
      |> Enum.filter(fn asset ->
        asset["class"] == "crypto" or asset["symbol"] in relationship_symbols
      end)

    results =
      Enum.map(assets, fn asset ->
        {:ok, arb} = is_in_arbitrage_position(ctx, asset["symbol"])
        arb
      end)

    hits = Enum.filter(results, & &1.result)
    {length(results), hits}
  end

  # Execute a single-leg or pair trade based on tier
  defp execute_arb_trade(ctx, _arb, %{pair: true, legs: legs}) do
    Enum.map(legs, fn leg ->
      leg_ctx = build_leg_context(ctx, leg["symbol"])
      {:ok, purchase} = execute_trade(leg_ctx, leg)
      purchase
    end)
  end

  defp execute_arb_trade(ctx, arb, params) do
    trade_ctx = build_leg_context(ctx, arb.asset)
    {:ok, purchase} = execute_trade(trade_ctx, params)
    [purchase]
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

  # Tier 1: single-leg directional trade
  defp build_order_params(%ArbitragePosition{tier: 1} = arb) do
    %{
      "side" => if(arb.spread && arb.spread < 0, do: "sell", else: "buy"),
      "qty" => "1",
      "type" => "market"
    }
  end

  # Tier 2/3: pair trade — long one side, short the other
  defp build_order_params(%ArbitragePosition{tier: tier} = arb)
       when tier in [2, 3] do
    {long_symbol, short_symbol} =
      case arb.direction do
        :long_a_short_b -> {arb.asset, arb.pair_asset}
        :long_b_short_a -> {arb.pair_asset, arb.asset}
      end

    %{
      pair: true,
      legs: [
        %{"symbol" => long_symbol, "side" => "buy", "qty" => "1", "type" => "market"},
        %{"symbol" => short_symbol, "side" => "sell", "qty" => "1", "type" => "market"}
      ]
    }
  end

  defp build_order_params(_arb) do
    %{"side" => "buy", "qty" => "1", "type" => "market"}
  end
end
