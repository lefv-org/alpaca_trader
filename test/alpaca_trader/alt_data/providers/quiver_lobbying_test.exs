defmodule AlpacaTrader.AltData.Providers.QuiverLobbyingTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.AltData.Providers.QuiverLobbying
  alias AlpacaTrader.AltData.SignalStore

  @plug AlpacaTrader.AltData.Quiver.Client

  setup do
    Application.put_env(:alpaca_trader, :quiverquant_api_key, "test-key")
    Application.put_env(:alpaca_trader, :quiver_lobbying_enabled, true)
    Application.put_env(:alpaca_trader, :quiver_lobbying_poll_s, 43_200)

    case Process.whereis(SignalStore) do
      nil -> {:ok, _} = SignalStore.start_link([])
      _ -> :ok
    end

    :ets.delete_all_objects(:alt_data_signals)
    :ok
  end

  test "fetch/0 hits /live/lobbying" do
    Req.Test.stub(@plug, fn conn ->
      assert String.ends_with?(conn.request_path, "/live/lobbying")
      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = QuiverLobbying.fetch()
  end

  test "fetch/0 inert when key missing" do
    Application.delete_env(:alpaca_trader, :quiverquant_api_key)
    assert {:ok, []} = QuiverLobbying.fetch()
  end

  test "provider_id/0 and poll_interval_ms/0" do
    assert QuiverLobbying.provider_id() == :quiver_lobbying
    assert QuiverLobbying.poll_interval_ms() == 43_200_000
  end
end
