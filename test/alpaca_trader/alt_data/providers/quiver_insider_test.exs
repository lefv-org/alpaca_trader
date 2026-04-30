defmodule AlpacaTrader.AltData.Providers.QuiverInsiderTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.AltData.Providers.QuiverInsider
  alias AlpacaTrader.AltData.SignalStore

  @plug AlpacaTrader.AltData.Quiver.Client

  setup do
    Application.put_env(:alpaca_trader, :quiverquant_api_key, "test-key")
    Application.put_env(:alpaca_trader, :quiver_insider_enabled, true)
    Application.put_env(:alpaca_trader, :quiver_insider_poll_s, 900)
    Application.put_env(:alpaca_trader, :quiver_insider_lookback_d, 30)

    case Process.whereis(SignalStore) do
      nil -> {:ok, _} = SignalStore.start_link([])
      _ -> :ok
    end

    :ets.delete_all_objects(:alt_data_signals)
    :ok
  end

  test "fetch/0 hits /live/insiders" do
    Req.Test.stub(@plug, fn conn ->
      assert String.ends_with?(conn.request_path, "/live/insiders")
      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = QuiverInsider.fetch()
  end

  test "fetch/0 inert when key missing" do
    Application.delete_env(:alpaca_trader, :quiverquant_api_key)
    assert {:ok, []} = QuiverInsider.fetch()
  end

  test "provider_id/0 and poll_interval_ms/0" do
    assert QuiverInsider.provider_id() == :quiver_insider
    assert QuiverInsider.poll_interval_ms() == 900_000
  end
end
