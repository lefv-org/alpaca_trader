defmodule AlpacaTrader.AltData.Providers.QuiverCongressTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.AltData.Providers.QuiverCongress
  alias AlpacaTrader.AltData.SignalStore

  @plug AlpacaTrader.AltData.Quiver.Client

  setup do
    Application.put_env(:alpaca_trader, :quiverquant_api_key, "test-key")
    Application.put_env(:alpaca_trader, :quiver_base_url, "https://api.quiverquant.com/beta")
    Application.put_env(:alpaca_trader, :quiver_congress_enabled, true)
    Application.put_env(:alpaca_trader, :quiver_congress_poll_s, 1800)
    Application.put_env(:alpaca_trader, :quiver_congress_lookback_d, 14)

    case Process.whereis(SignalStore) do
      nil -> {:ok, _} = SignalStore.start_link([])
      _ -> :ok
    end

    :ets.delete_all_objects(:alt_data_signals)
    :ok
  end

  test "fetch/0 calls bulk/congresstrading and returns parsed signals" do
    today = Date.utc_today() |> Date.to_iso8601()

    Req.Test.stub(@plug, fn conn ->
      assert String.ends_with?(conn.request_path, "/bulk/congresstrading")

      Req.Test.json(conn, [
        %{
          "Ticker" => "AAPL",
          "Transaction" => "Purchase",
          "TransactionDate" => today,
          "Representative" => "X",
          "Range" => "$1-$15K"
        }
      ])
    end)

    assert {:ok, [signal]} = QuiverCongress.fetch()
    assert signal.provider == :quiver_congress
    assert signal.affected_symbols == ["AAPL"]
  end

  test "fetch/0 returns {:ok, []} when api key is missing (inert)" do
    Application.delete_env(:alpaca_trader, :quiverquant_api_key)
    assert {:ok, []} = QuiverCongress.fetch()
  end

  test "fetch/0 surfaces client errors" do
    Req.Test.stub(@plug, fn conn ->
      Plug.Conn.send_resp(conn, 503, ~s({"err":"down"}))
    end)

    assert {:error, _} = QuiverCongress.fetch()
  end

  test "provider_id/0 and poll_interval_ms/0 honor config" do
    assert QuiverCongress.provider_id() == :quiver_congress
    assert QuiverCongress.poll_interval_ms() == 1_800_000
  end
end
