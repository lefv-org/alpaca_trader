defmodule AlpacaTrader.Brokers.AlpacaTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.Brokers.Alpaca
  alias AlpacaTrader.Types.Order

  setup do
    Application.put_env(:alpaca_trader, :req_plug, {Req.Test, :alpaca})
    Application.put_env(:alpaca_trader, :alpaca_base_url, "https://example.com")
    Application.put_env(:alpaca_trader, :alpaca_key_id, "test-key")
    Application.put_env(:alpaca_trader, :alpaca_secret_key, "test-secret")
    on_exit(fn -> Application.delete_env(:alpaca_trader, :req_plug) end)
    :ok
  end

  test "positions/0 decodes Alpaca JSON into %Position{} list" do
    Req.Test.stub(:alpaca, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Req.Test.json([%{
        "symbol" => "AAPL", "qty" => "10", "avg_entry_price" => "150.00",
        "market_value" => "1500", "asset_class" => "us_equity",
        "current_price" => "150.00"
      }])
    end)
    assert {:ok, [pos]} = Alpaca.positions()
    assert pos.venue == :alpaca
    assert pos.symbol == "AAPL"
    assert pos.asset_class == :equity
    assert Decimal.equal?(pos.qty, Decimal.new("10"))
  end

  test "submit_order/2 converts %Order{} to Alpaca body and decodes response" do
    Req.Test.stub(:alpaca, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["symbol"] == "AAPL"
      assert decoded["side"] == "buy"
      assert decoded["notional"] == "100.00"
      Req.Test.json(conn, %{
        "id" => "abc-123", "status" => "accepted",
        "symbol" => "AAPL", "filled_qty" => "0", "side" => "buy"
      })
    end)
    order = Order.new(venue: :alpaca, symbol: "AAPL", side: :buy, type: :market,
                      size: Decimal.new("100"), size_mode: :notional)
    assert {:ok, sub} = Alpaca.submit_order(order, [])
    assert sub.id == "abc-123"
    assert sub.status == :submitted
  end

  test "account/0 decodes Alpaca account JSON" do
    Req.Test.stub(:alpaca, fn conn ->
      Req.Test.json(conn, %{
        "equity" => "10000", "cash" => "8000", "buying_power" => "20000",
        "daytrade_count" => "2", "pattern_day_trader" => false, "currency" => "USD"
      })
    end)
    assert {:ok, acc} = Alpaca.account()
    assert acc.venue == :alpaca
    assert Decimal.equal?(acc.equity, Decimal.new("10000"))
    assert acc.daytrade_count == 2
    assert acc.currency == "USD"
  end

  test "capabilities/0 reports equity venue shape" do
    caps = Alpaca.capabilities()
    assert caps.perps == false
    assert caps.hours == :rth
  end

  test "funding_rate/1 returns :not_supported" do
    assert {:error, :not_supported} = Alpaca.funding_rate("anything")
  end
end
