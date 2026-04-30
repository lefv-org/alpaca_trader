defmodule AlpacaTrader.AltData.Providers.QuiverGovContractsTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.AltData.Providers.QuiverGovContracts
  alias AlpacaTrader.AltData.SignalStore

  @plug AlpacaTrader.AltData.Quiver.Client

  setup do
    Application.put_env(:alpaca_trader, :quiverquant_api_key, "test-key")
    Application.put_env(:alpaca_trader, :quiver_govcontracts_enabled, true)
    Application.put_env(:alpaca_trader, :quiver_govcontracts_poll_s, 10800)
    Application.put_env(:alpaca_trader, :quiver_govcontracts_lookback_d, 30)

    case Process.whereis(SignalStore) do
      nil -> {:ok, _} = SignalStore.start_link([])
      _ -> :ok
    end

    :ets.delete_all_objects(:alt_data_signals)
    :ok
  end

  test "fetch/0 hits /live/govcontractsall" do
    Req.Test.stub(@plug, fn conn ->
      assert String.ends_with?(conn.request_path, "/live/govcontractsall")
      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = QuiverGovContracts.fetch()
  end

  test "fetch/0 inert when key missing" do
    Application.delete_env(:alpaca_trader, :quiverquant_api_key)
    assert {:ok, []} = QuiverGovContracts.fetch()
  end

  test "provider_id/0 and poll_interval_ms/0" do
    assert QuiverGovContracts.provider_id() == :quiver_govcontracts
    assert QuiverGovContracts.poll_interval_ms() == 10_800_000
  end
end
