defmodule AlpacaTrader.AltData.Quiver.ClientTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.AltData.Quiver.Client

  @plug AlpacaTrader.AltData.Quiver.Client

  setup do
    Application.put_env(:alpaca_trader, :quiverquant_api_key, "test-key")
    Application.put_env(:alpaca_trader, :quiver_base_url, "https://api.quiverquant.com/beta")
    Application.put_env(:alpaca_trader, :quiver_timeout_ms, 5_000)
    :ok
  end

  test "get/2 sends bearer auth and returns decoded body on 200" do
    Req.Test.stub(@plug, fn conn ->
      assert ["Bearer test-key"] = Plug.Conn.get_req_header(conn, "authorization")
      Req.Test.json(conn, [%{"Ticker" => "AAPL"}])
    end)

    assert {:ok, [%{"Ticker" => "AAPL"}]} = Client.get("/bulk/congresstrading", %{})
  end

  test "get/2 retries on 429 then succeeds" do
    counter = :counters.new(1, [:atomics])

    Req.Test.stub(@plug, fn conn ->
      n = :counters.add(counter, 1, 1) && :counters.get(counter, 1)

      if n < 3 do
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(429, ~s({"error":"rate limited"}))
      else
        Req.Test.json(conn, [%{"ok" => true}])
      end
    end)

    assert {:ok, [%{"ok" => true}]} = Client.get("/x", %{})
    assert :counters.get(counter, 1) == 3
  end

  test "get/2 returns error after exhausting retries on 5xx" do
    Req.Test.stub(@plug, fn conn ->
      Plug.Conn.send_resp(conn, 503, ~s({"error":"down"}))
    end)

    assert {:error, {:http_status, 503, _}} = Client.get("/x", %{})
  end

  test "get/2 returns :no_api_key when key missing" do
    Application.delete_env(:alpaca_trader, :quiverquant_api_key)
    assert {:error, :no_api_key} = Client.get("/x", %{})
  end

  test "get/2 surfaces 401 immediately as :unauthorized (no retry)" do
    counter = :counters.new(1, [:atomics])

    Req.Test.stub(@plug, fn conn ->
      :counters.add(counter, 1, 1)
      Plug.Conn.send_resp(conn, 401, ~s({"error":"unauthorized"}))
    end)

    assert {:error, :unauthorized} = Client.get("/x", %{})
    assert :counters.get(counter, 1) == 1
  end
end
