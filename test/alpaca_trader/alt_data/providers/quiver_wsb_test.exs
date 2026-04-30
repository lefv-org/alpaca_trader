defmodule AlpacaTrader.AltData.Providers.QuiverWsbTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.AltData.Providers.QuiverWsb
  alias AlpacaTrader.AltData.SignalStore

  @plug AlpacaTrader.AltData.Quiver.Client

  setup do
    Application.put_env(:alpaca_trader, :quiverquant_api_key, "test-key")
    Application.put_env(:alpaca_trader, :quiver_wsb_enabled, true)
    Application.put_env(:alpaca_trader, :quiver_wsb_poll_s, 450)

    case Process.whereis(SignalStore) do
      nil -> {:ok, _} = SignalStore.start_link([])
      _ -> :ok
    end

    :ets.delete_all_objects(:alt_data_signals)
    :ok
  end

  test "fetch/0 hits /live/wallstreetbets" do
    Req.Test.stub(@plug, fn conn ->
      assert String.ends_with?(conn.request_path, "/live/wallstreetbets")
      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = QuiverWsb.fetch()
  end

  test "fetch/0 inert when key missing" do
    Application.delete_env(:alpaca_trader, :quiverquant_api_key)
    assert {:ok, []} = QuiverWsb.fetch()
  end

  test "provider_id/0 and poll_interval_ms/0" do
    assert QuiverWsb.provider_id() == :quiver_wsb
    assert QuiverWsb.poll_interval_ms() == 450_000
  end
end
