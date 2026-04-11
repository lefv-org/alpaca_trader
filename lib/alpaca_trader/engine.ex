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
      :orders
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
  The single point in the app where buy/sell/hold logic occurs.

  Takes a MarketContext (raw market data), evaluates it, and returns
  a PurchaseContext with the recommendation.

  Strategy logic will be added here. For now, returns :hold.
  """
  def execute_trade(%MarketContext{} = ctx) do
    {:ok,
     %PurchaseContext{
       action: :hold,
       symbol: ctx.symbol,
       reason: "no strategy configured",
       qty: nil,
       side: nil,
       order: nil,
       timestamp: DateTime.utc_now()
     }}
  end

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
  Checks whether the given asset has an arbitrage position.

  Takes a MarketContext and an asset name, returns an ArbitragePosition
  indicating whether an arbitrage condition exists.

  Detection logic will be added here. For now, returns result: false.
  """
  def is_in_arbitrage_position(%MarketContext{} = ctx, asset) do
    related =
      (ctx.positions || [])
      |> Enum.filter(fn p -> String.contains?(p["symbol"], asset) end)

    {:ok,
     %ArbitragePosition{
       result: false,
       asset: asset,
       reason: "no arbitrage detection configured",
       related_positions: related,
       spread: nil,
       timestamp: DateTime.utc_now()
     }}
  end
end
