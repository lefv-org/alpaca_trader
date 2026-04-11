defmodule AlpacaTrader.Scheduler.Jobs.BarsSyncJobTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.Scheduler.Jobs.BarsSyncJob
  alias AlpacaTrader.BarsStore

  test "job_id returns bars-sync" do
    assert BarsSyncJob.job_id() == "bars-sync"
  end

  test "job_name returns Historical Bars Sync" do
    assert BarsSyncJob.job_name() == "Historical Bars Sync"
  end

  test "schedule returns top-of-hour cron" do
    assert BarsSyncJob.schedule() == "0 * * * *"
  end

  test "run fetches bars and stores them" do
    Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
      case conn.request_path do
        "/v2/stocks/bars" ->
          Req.Test.json(conn, %{
            "bars" => %{
              "AAPL" => [
                %{"t" => "2026-04-10T00:00:00Z", "c" => 185.0, "o" => 183.0, "h" => 186.0, "l" => 182.0, "v" => 1000}
              ],
              "MSFT" => [
                %{"t" => "2026-04-10T00:00:00Z", "c" => 420.0, "o" => 418.0, "h" => 422.0, "l" => 417.0, "v" => 2000}
              ]
            }
          })

        "/v1beta3/crypto/us/bars" ->
          Req.Test.json(conn, %{
            "bars" => %{
              "BTC/USD" => [
                %{"t" => "2026-04-10T00:00:00Z", "c" => 70000.0, "o" => 69000.0, "h" => 71000.0, "l" => 68500.0, "v" => 500}
              ]
            }
          })

        _ ->
          Req.Test.json(conn, %{})
      end
    end)

    assert {:ok, count} = BarsSyncJob.run()
    assert count > 0

    # Verify bars were stored
    assert {:ok, bars} = BarsStore.get("AAPL")
    assert length(bars) > 0

    assert {:ok, btc_bars} = BarsStore.get("BTC/USD")
    assert length(btc_bars) > 0
  end

  test "run handles API errors gracefully" do
    Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(403, Jason.encode!(%{"message" => "forbidden"}))
    end)

    assert {:error, _reason} = BarsSyncJob.run()
  end
end
