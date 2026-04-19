defmodule AlpacaTrader.Scheduler.Jobs.AssetSyncJobTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.Scheduler.Jobs.AssetSyncJob
  alias AlpacaTrader.AssetStore

  test "job_id returns asset-sync" do
    assert AssetSyncJob.job_id() == "asset-sync"
  end

  test "schedule returns every-minute cron" do
    assert AssetSyncJob.schedule() == "* * * * *"
  end

  test "run fetches assets and stores tradeable ones" do
    Req.Test.stub(AlpacaTrader.Alpaca.Client, fn conn ->
      assert conn.request_path == "/v2/assets"

      Req.Test.json(conn, [
        %{"symbol" => "AAPL", "tradable" => true, "name" => "Apple"},
        %{"symbol" => "DELISTED", "tradable" => false, "name" => "Gone"},
        %{"symbol" => "BTC/USD", "tradable" => true, "name" => "Bitcoin"}
      ])
    end)

    assert {:ok, 2} = AssetSyncJob.run()
    assert AssetStore.count() == 2
    assert {:ok, _} = AssetStore.get("AAPL")
    assert {:ok, _} = AssetStore.get("BTC/USD")
    assert :error = AssetStore.get("DELISTED")
  end
end
