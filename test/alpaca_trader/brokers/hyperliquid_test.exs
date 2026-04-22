defmodule AlpacaTrader.Brokers.HyperliquidTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.Brokers.Hyperliquid

  @plug AlpacaTrader.Brokers.Hyperliquid.Client

  setup do
    Application.put_env(:alpaca_trader, :hyperliquid_req_plug, {Req.Test, @plug})
    on_exit(fn -> Application.delete_env(:alpaca_trader, :hyperliquid_req_plug) end)
    :ok
  end

  test "capabilities reports perps venue" do
    caps = Hyperliquid.capabilities()
    assert caps.shorting
    assert caps.perps
    assert caps.hours == :h24
  end

  test "funding_rate/1 decodes HL metaAndAssetCtxs response" do
    Req.Test.stub(@plug, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["type"] == "metaAndAssetCtxs"
      # HL returns [meta, ctxs] tuple-as-list
      Req.Test.json(conn, [
        %{"universe" => [%{"name" => "BTC"}]},
        [%{"funding" => "0.00032"}]
      ])
    end)

    assert {:ok, rate} = Hyperliquid.funding_rate("BTC")
    assert Decimal.equal?(rate, Decimal.new("0.00032"))
  end

  test "positions/0 decodes clearinghouseState assetPositions" do
    Application.put_env(:alpaca_trader, :hyperliquid_wallet_addr, "0xabc")

    Req.Test.stub(@plug, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["type"] == "clearinghouseState"
      assert decoded["user"] == "0xabc"

      Req.Test.json(conn, %{
        "assetPositions" => [
          %{"position" => %{"coin" => "BTC", "szi" => "0.5", "entryPx" => "60000"}}
        ],
        "marginSummary" => %{"accountValue" => "1000", "totalRawUsd" => "500"}
      })
    end)

    assert {:ok, [pos]} = Hyperliquid.positions()
    assert pos.venue == :hyperliquid
    assert pos.symbol == "BTC"
    assert pos.asset_class == :perp
    assert Decimal.equal?(pos.qty, Decimal.new("0.5"))
  end

  test "account/0 decodes marginSummary into %Account{}" do
    Application.put_env(:alpaca_trader, :hyperliquid_wallet_addr, "0xabc")

    Req.Test.stub(@plug, fn conn ->
      Req.Test.json(conn, %{
        "assetPositions" => [],
        "marginSummary" => %{"accountValue" => "1000", "totalRawUsd" => "500"}
      })
    end)

    assert {:ok, acc} = Hyperliquid.account()
    assert acc.venue == :hyperliquid
    assert Decimal.equal?(acc.equity, Decimal.new("1000"))
  end
end
