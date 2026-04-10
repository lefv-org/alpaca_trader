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

  # --- Positions ---

  describe "list_positions/0" do
    test "makes GET to /v2/positions" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.request_path == "/v2/positions"
        Req.Test.json(conn, [%{"symbol" => "AAPL", "qty" => "10"}])
      end)

      assert {:ok, [%{"symbol" => "AAPL"}]} = Client.list_positions()
    end
  end

  describe "get_position/1" do
    test "makes GET to /v2/positions/:symbol" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.request_path == "/v2/positions/AAPL"
        Req.Test.json(conn, %{"symbol" => "AAPL"})
      end)

      assert {:ok, %{"symbol" => "AAPL"}} = Client.get_position("AAPL")
    end
  end

  describe "close_position/2" do
    test "makes DELETE to /v2/positions/:symbol" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/v2/positions/AAPL"
        Req.Test.json(conn, %{"symbol" => "AAPL"})
      end)

      assert {:ok, _} = Client.close_position("AAPL", %{})
    end
  end

  describe "close_all_positions/1" do
    test "makes DELETE to /v2/positions" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/v2/positions"
        Req.Test.json(conn, [])
      end)

      assert {:ok, _} = Client.close_all_positions(%{cancel_orders: true})
    end
  end

  # --- Assets ---

  describe "list_assets/1" do
    test "makes GET to /v2/assets" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.request_path == "/v2/assets"
        Req.Test.json(conn, [%{"symbol" => "AAPL", "class" => "us_equity"}])
      end)

      assert {:ok, [%{"symbol" => "AAPL"}]} = Client.list_assets(%{status: "active"})
    end
  end

  describe "get_asset/1" do
    test "makes GET to /v2/assets/:symbol" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.request_path == "/v2/assets/AAPL"
        Req.Test.json(conn, %{"symbol" => "AAPL"})
      end)

      assert {:ok, %{"symbol" => "AAPL"}} = Client.get_asset("AAPL")
    end
  end

  # --- Watchlists ---

  describe "list_watchlists/0" do
    test "makes GET to /v2/watchlists" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.request_path == "/v2/watchlists"
        Req.Test.json(conn, [%{"id" => "wl1", "name" => "My List"}])
      end)

      assert {:ok, [%{"id" => "wl1"}]} = Client.list_watchlists()
    end
  end

  describe "create_watchlist/1" do
    test "makes POST to /v2/watchlists" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2/watchlists"
        Req.Test.json(conn, %{"id" => "wl1", "name" => "Tech"})
      end)

      assert {:ok, %{"id" => "wl1"}} =
               Client.create_watchlist(%{name: "Tech", symbols: ["AAPL"]})
    end
  end

  describe "get_watchlist/1" do
    test "makes GET to /v2/watchlists/:id" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.request_path == "/v2/watchlists/wl1"
        Req.Test.json(conn, %{"id" => "wl1", "assets" => []})
      end)

      assert {:ok, %{"id" => "wl1"}} = Client.get_watchlist("wl1")
    end
  end

  describe "update_watchlist/2" do
    test "makes PUT to /v2/watchlists/:id" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/v2/watchlists/wl1"
        Req.Test.json(conn, %{"id" => "wl1"})
      end)

      assert {:ok, _} =
               Client.update_watchlist("wl1", %{name: "Tech 2", symbols: ["AAPL", "MSFT"]})
    end
  end

  describe "delete_watchlist/1" do
    test "makes DELETE to /v2/watchlists/:id" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/v2/watchlists/wl1"
        Req.Test.json(conn, %{})
      end)

      assert {:ok, _} = Client.delete_watchlist("wl1")
    end
  end

  describe "add_to_watchlist/2" do
    test "makes POST to /v2/watchlists/:id" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2/watchlists/wl1"
        Req.Test.json(conn, %{"id" => "wl1"})
      end)

      assert {:ok, _} = Client.add_to_watchlist("wl1", "TSLA")
    end
  end

  describe "remove_from_watchlist/2" do
    test "makes DELETE to /v2/watchlists/:id/:symbol" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/v2/watchlists/wl1/TSLA"
        Req.Test.json(conn, %{"id" => "wl1"})
      end)

      assert {:ok, _} = Client.remove_from_watchlist("wl1", "TSLA")
    end
  end

  # --- Market ---

  describe "get_clock/0" do
    test "makes GET to /v2/clock" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.request_path == "/v2/clock"
        Req.Test.json(conn, %{"is_open" => true, "next_open" => "2026-04-11T09:30:00-04:00"})
      end)

      assert {:ok, %{"is_open" => true}} = Client.get_clock()
    end
  end

  describe "get_calendar/1" do
    test "makes GET to /v2/calendar" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.request_path == "/v2/calendar"
        Req.Test.json(conn, [%{"date" => "2026-04-10", "open" => "09:30", "close" => "16:00"}])
      end)

      assert {:ok, [%{"date" => "2026-04-10"}]} = Client.get_calendar(%{start: "2026-04-10"})
    end
  end

  describe "get_corporate_actions/1" do
    test "makes GET to /v2/corporate_actions/announcements" do
      Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
        assert conn.request_path == "/v2/corporate_actions/announcements"
        Req.Test.json(conn, [%{"id" => "ca1", "ca_type" => "dividend"}])
      end)

      assert {:ok, [%{"id" => "ca1"}]} =
               Client.get_corporate_actions(%{ca_types: "dividend", since: "2026-01-01"})
    end
  end
end
