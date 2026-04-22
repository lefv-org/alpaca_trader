defmodule AlpacaTrader.Brokers.Hyperliquid do
  @moduledoc """
  Hyperliquid Broker implementation. REST + stubbed signing (see Auth).
  Read-only paths (positions, account, funding_rate) work against testnet/mainnet
  without a signing key. Submit path requires real Auth module (TODO — Phase 2+).
  """
  @behaviour AlpacaTrader.Broker

  alias AlpacaTrader.Brokers.Hyperliquid.{Client, Auth}
  alias AlpacaTrader.Types.{Order, Position, Account, Capabilities}

  @impl true
  def submit_order(%Order{} = order, _opts) do
    action = %{
      "type" => "order",
      "orders" => [
        %{
          "coin" => order.symbol,
          "is_buy" => order.side == :buy,
          "sz" => Decimal.to_string(order.size, :normal),
          "limit_px" => order.limit_price && Decimal.to_string(order.limit_price, :normal),
          "order_type" => %{"market" => %{}},
          "reduce_only" => false
        }
      ]
    }

    with {:ok, sig} <- Auth.sign(action),
         {:ok, resp} <-
           Client.post("/exchange", %{
             "action" => action,
             "signature" => sig,
             "nonce" => System.system_time(:millisecond)
           }) do
      {:ok, %{order | status: :submitted, raw: resp, id: resp["id"] || resp["oid"]}}
    end
  end

  @impl true
  def cancel_order(_id), do: {:error, :not_implemented_yet}

  @impl true
  def positions do
    addr = Application.get_env(:alpaca_trader, :hyperliquid_wallet_addr)

    with {:ok, resp} <- Client.post("/info", %{"type" => "clearinghouseState", "user" => addr}) do
      positions = (resp["assetPositions"] || []) |> Enum.map(&decode_position/1)
      {:ok, positions}
    end
  end

  @impl true
  def account do
    addr = Application.get_env(:alpaca_trader, :hyperliquid_wallet_addr)

    with {:ok, resp} <- Client.post("/info", %{"type" => "clearinghouseState", "user" => addr}) do
      summary = resp["marginSummary"] || %{}

      {:ok,
       %Account{
         venue: :hyperliquid,
         equity: to_dec(summary["accountValue"] || "0"),
         cash: to_dec(summary["totalRawUsd"] || "0"),
         buying_power: to_dec(summary["totalRawUsd"] || "0"),
         raw: resp
       }}
    end
  end

  @impl true
  def bars(_symbol, _opts), do: {:ok, []}

  @impl true
  def funding_rate(symbol) do
    with {:ok, resp} <- Client.post("/info", %{"type" => "metaAndAssetCtxs"}) do
      rate =
        case resp do
          [%{"universe" => universe}, ctxs] when is_list(universe) and is_list(ctxs) ->
            idx = Enum.find_index(universe, &(&1["name"] == symbol))

            case idx && Enum.at(ctxs, idx) do
              %{"funding" => f} -> to_dec(f)
              _ -> Decimal.new(0)
            end

          _ ->
            Decimal.new(0)
        end

      {:ok, rate}
    end
  end

  @impl true
  def capabilities do
    %Capabilities{
      shorting: true,
      perps: true,
      fractional: true,
      min_notional: Decimal.new("10"),
      fee_bps: 5,
      hours: :h24
    }
  end

  defp decode_position(%{"position" => p}) do
    %Position{
      venue: :hyperliquid,
      symbol: p["coin"],
      qty: to_dec(p["szi"]),
      avg_entry: to_dec(p["entryPx"] || "0"),
      asset_class: :perp,
      raw: p
    }
  end

  defp to_dec(nil), do: Decimal.new(0)
  defp to_dec(%Decimal{} = d), do: d
  defp to_dec(s) when is_binary(s), do: Decimal.new(s)
  defp to_dec(n) when is_integer(n), do: Decimal.new(n)
  defp to_dec(n) when is_float(n), do: Decimal.from_float(n)
end
