defmodule AlpacaTrader.Engine do
  @moduledoc """
  Single entry point for all trade decisions.
  """

  defmodule MarketContext do
    @moduledoc """
    Raw market data fed into execute_trade/1.
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
    Result of execute_trade/1 — wraps the buy/sell/hold recommendation.
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

  defmodule ArbitragePosition do
    @moduledoc """
    Result of is_in_arbitrage_position/2 — describes whether an arbitrage
    opportunity or position exists for a given asset.
    """
    @derive Jason.Encoder
    defstruct [
      :result,
      :asset,
      :reason,
      :related_positions,
      :spread,
      :timestamp
    ]
  end

  @doc """
  Checks whether the given asset has an arbitrage opportunity.

  Uses Bellman-Ford negative-cycle detection on the crypto price graph
  from ctx.quotes. Returns result: true if the asset's base currency
  appears in a profitable cycle.
  """
  def is_in_arbitrage_position(%MarketContext{} = ctx, asset) do
    related =
      (ctx.positions || [])
      |> Enum.filter(fn p -> String.contains?(p["symbol"], asset) end)

    # Extract the base currency (e.g., "BTC/USD" → "BTC", "AAPL" → "AAPL")
    currency = asset |> String.split("/") |> hd()

    case ctx.quotes do
      quotes when is_map(quotes) and map_size(quotes) > 0 ->
        cycles = AlpacaTrader.Arbitrage.BellmanFord.detect_cycles(quotes)

        case AlpacaTrader.Arbitrage.BellmanFord.currency_in_cycles?(currency, cycles) do
          %{cycle: cycle, profit_pct: profit} ->
            {:ok,
             %ArbitragePosition{
               result: true,
               asset: asset,
               reason: "arbitrage cycle detected: #{Enum.join(cycle, " → ")} (#{profit}%)",
               related_positions: related,
               spread: profit,
               timestamp: DateTime.utc_now()
             }}

          nil ->
            {:ok,
             %ArbitragePosition{
               result: false,
               asset: asset,
               reason: "no profitable cycle includes #{currency}",
               related_positions: related,
               spread: nil,
               timestamp: DateTime.utc_now()
             }}
        end

      _ ->
        {:ok,
         %ArbitragePosition{
           result: false,
           asset: asset,
           reason: "no quote data available",
           related_positions: related,
           spread: nil,
           timestamp: DateTime.utc_now()
         }}
    end
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

  @doc """
  Scans all tradeable assets for arbitrage opportunities (dry run — no trades).
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
  Full pipeline: scan all assets → detect arbitrage → execute trades.

  For each asset in the AssetStore:
    1. is_in_arbitrage_position/2
    2. If result: true → execute_trade/2
    3. Collect all results

  This is the function called by the ArbitrageScanJob cron.
  """
  def scan_and_execute(%MarketContext{} = ctx) do
    {scanned, hits} = do_scan(ctx)

    trades =
      Enum.map(hits, fn arb ->
        asset_data = AlpacaTrader.AssetStore.get(arb.asset)

        trade_ctx = %MarketContext{
          ctx
          | symbol: arb.asset,
            asset: case asset_data do
              {:ok, a} -> a
              :error -> %{"tradable" => true, "class" => "us_equity"}
            end,
            position: Enum.find(ctx.positions || [], fn p -> p["symbol"] == arb.asset end)
        }

        order_params = build_order_params(arb)
        {:ok, purchase} = execute_trade(trade_ctx, order_params)
        purchase
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

  defp do_scan(ctx) do
    assets = AlpacaTrader.AssetStore.all()

    results =
      Enum.map(assets, fn asset ->
        {:ok, arb} = is_in_arbitrage_position(ctx, asset["symbol"])
        arb
      end)

    hits = Enum.filter(results, & &1.result)
    {length(results), hits}
  end

  defp build_order_params(%ArbitragePosition{} = arb) do
    # Determine trade direction from the arbitrage signal.
    # Strategy logic goes here — for now, defaults to buy.
    %{
      "side" => arb.spread && arb.spread < 0 && "sell" || "buy",
      "qty" => "1",
      "type" => "market"
    }
  end
end
