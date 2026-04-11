defmodule AlpacaTrader.AssetStoreTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.AssetStore

  setup do
    # Clear store between tests
    AssetStore.put_assets([])
    :ok
  end

  test "starts empty" do
    assert AssetStore.count() == 0
    assert AssetStore.all() == []
  end

  test "put_assets stores and retrieves assets" do
    assets = [
      %{"symbol" => "AAPL", "name" => "Apple", "tradable" => true},
      %{"symbol" => "BTC/USD", "name" => "Bitcoin", "tradable" => true}
    ]

    AssetStore.put_assets(assets)
    assert AssetStore.count() == 2
  end

  test "get returns asset by symbol" do
    AssetStore.put_assets([%{"symbol" => "AAPL", "name" => "Apple"}])

    assert {:ok, %{"symbol" => "AAPL"}} = AssetStore.get("AAPL")
    assert :error = AssetStore.get("NOPE")
  end

  test "put_assets replaces previous data" do
    AssetStore.put_assets([%{"symbol" => "AAPL"}])
    assert AssetStore.count() == 1

    AssetStore.put_assets([%{"symbol" => "MSFT"}, %{"symbol" => "GOOG"}])
    assert AssetStore.count() == 2
    assert :error = AssetStore.get("AAPL")
  end

  test "last_synced_at returns timestamp after put" do
    # put_assets always sets the timestamp, so just verify it's a DateTime
    AssetStore.put_assets([%{"symbol" => "AAPL"}])
    assert %DateTime{} = AssetStore.last_synced_at()
  end
end
