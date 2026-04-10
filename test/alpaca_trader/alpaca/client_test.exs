defmodule AlpacaTrader.Alpaca.ClientTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Alpaca.Client

  describe "get_account/0" do
    test "makes GET to /v2/account" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v2/account"
        Req.Test.json(conn, %{"id" => "abc123", "status" => "ACTIVE"})
      end)

      assert {:ok, %{"id" => "abc123", "status" => "ACTIVE"}} = Client.get_account()
    end
  end

  describe "get_account_config/0" do
    test "makes GET to /v2/account/configurations" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v2/account/configurations"
        Req.Test.json(conn, %{"dtbp_check" => "both", "no_shorting" => false})
      end)

      assert {:ok, %{"dtbp_check" => "both"}} = Client.get_account_config()
    end
  end

  describe "update_account_config/1" do
    test "makes PATCH to /v2/account/configurations with body" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/v2/account/configurations"
        Req.Test.json(conn, %{"dtbp_check" => "entry"})
      end)

      assert {:ok, %{"dtbp_check" => "entry"}} =
               Client.update_account_config(%{"dtbp_check" => "entry"})
    end
  end

  describe "get_activities/1" do
    test "makes GET to /v2/account/activities" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v2/account/activities"
        Req.Test.json(conn, [%{"id" => "act1", "activity_type" => "FILL"}])
      end)

      assert {:ok, [%{"id" => "act1"}]} = Client.get_activities(%{activity_type: "FILL"})
    end
  end

  describe "get_portfolio_history/1" do
    test "makes GET to /v2/account/portfolio/history" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v2/account/portfolio/history"
        Req.Test.json(conn, %{"equity" => [10_000.0], "timestamp" => [1_700_000_000]})
      end)

      assert {:ok, %{"equity" => [10_000.0]}} = Client.get_portfolio_history(%{period: "1D"})
    end
  end

  describe "list_orders/1" do
    test "makes GET to /v2/orders" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v2/orders"
        Req.Test.json(conn, [%{"id" => "o1", "status" => "new"}])
      end)

      assert {:ok, [%{"id" => "o1"}]} = Client.list_orders(%{status: "open"})
    end
  end

  describe "create_order/1" do
    test "makes POST to /v2/orders" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2/orders"
        Req.Test.json(conn, %{"id" => "o1", "symbol" => "AAPL"})
      end)

      assert {:ok, %{"id" => "o1"}} =
               Client.create_order(%{
                 symbol: "AAPL",
                 qty: "1",
                 side: "buy",
                 type: "market",
                 time_in_force: "day"
               })
    end
  end

  describe "get_order/1" do
    test "makes GET to /v2/orders/:id" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v2/orders/o1"
        Req.Test.json(conn, %{"id" => "o1"})
      end)

      assert {:ok, %{"id" => "o1"}} = Client.get_order("o1")
    end
  end

  describe "replace_order/2" do
    test "makes PATCH to /v2/orders/:id" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/v2/orders/o1"
        Req.Test.json(conn, %{"id" => "o1", "qty" => "2"})
      end)

      assert {:ok, %{"id" => "o1"}} = Client.replace_order("o1", %{qty: "2"})
    end
  end

  describe "cancel_order/1" do
    test "makes DELETE to /v2/orders/:id" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/v2/orders/o1"
        Req.Test.json(conn, %{})
      end)

      assert {:ok, _} = Client.cancel_order("o1")
    end
  end

  describe "cancel_all_orders/0" do
    test "makes DELETE to /v2/orders" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/v2/orders"
        Req.Test.json(conn, [])
      end)

      assert {:ok, _} = Client.cancel_all_orders()
    end
  end
end
