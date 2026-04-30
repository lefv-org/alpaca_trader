defmodule AlpacaTrader.AltData.QuiverSupervisorTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.AltData.SignalStore

  @plug AlpacaTrader.AltData.Quiver.Client

  @quiver_providers [
    AlpacaTrader.AltData.Providers.QuiverCongress,
    AlpacaTrader.AltData.Providers.QuiverInsider,
    AlpacaTrader.AltData.Providers.QuiverGovContracts,
    AlpacaTrader.AltData.Providers.QuiverLobbying,
    AlpacaTrader.AltData.Providers.QuiverWsb
  ]

  setup do
    Application.put_env(:alpaca_trader, :quiverquant_api_key, "test-key")
    Application.put_env(:alpaca_trader, :quiver_base_url, "https://api.quiverquant.com/beta")

    # Disable non-quiver providers so we don't trigger network from them.
    for k <- [
          :alt_data_fred_enabled,
          :alt_data_open_meteo_enabled,
          :alt_data_opensky_enabled,
          :alt_data_nasa_firms_enabled,
          :alt_data_nws_enabled,
          :alt_data_finnhub_enabled
        ] do
      Application.put_env(:alpaca_trader, k, false)
    end

    for k <- [
          :quiver_congress_enabled,
          :quiver_insider_enabled,
          :quiver_govcontracts_enabled,
          :quiver_lobbying_enabled,
          :quiver_wsb_enabled
        ] do
      Application.put_env(:alpaca_trader, k, true)
    end

    Application.put_env(:alpaca_trader, :quiver_congress_poll_s, 60)
    Application.put_env(:alpaca_trader, :quiver_insider_poll_s, 60)
    Application.put_env(:alpaca_trader, :quiver_govcontracts_poll_s, 60)
    Application.put_env(:alpaca_trader, :quiver_lobbying_poll_s, 60)
    Application.put_env(:alpaca_trader, :quiver_wsb_poll_s, 60)
    Application.put_env(:alpaca_trader, :quiver_congress_lookback_d, 14)
    Application.put_env(:alpaca_trader, :quiver_insider_lookback_d, 30)
    Application.put_env(:alpaca_trader, :quiver_govcontracts_lookback_d, 30)

    case Process.whereis(SignalStore) do
      nil -> {:ok, _} = SignalStore.start_link([])
      _ -> :ok
    end

    :ets.delete_all_objects(:alt_data_signals)

    today = Date.utc_today() |> Date.to_iso8601()

    Req.Test.stub(@plug, fn conn ->
      body =
        cond do
          String.ends_with?(conn.request_path, "/bulk/congresstrading") ->
            [
              %{
                "Ticker" => "AAPL",
                "Transaction" => "Purchase",
                "TransactionDate" => today,
                "Range" => "$1-$15K",
                "Representative" => "X"
              }
            ]

          String.ends_with?(conn.request_path, "/live/insiders") ->
            [
              %{
                "Ticker" => "AAPL",
                "Name" => "X",
                "Code" => "P",
                "Shares" => "100",
                "PricePerShare" => "100",
                "Date" => today
              }
            ]

          String.ends_with?(conn.request_path, "/live/govcontractsall") ->
            [
              %{
                "Ticker" => "LMT",
                "Amount" => "10000000",
                "Description" => "x",
                "Date" => today,
                "Agency" => "DOD"
              }
            ]

          String.ends_with?(conn.request_path, "/live/lobbying") ->
            [
              %{
                "Ticker" => "GOOGL",
                "Client" => "G",
                "Amount" => "1000000",
                "Year" => Date.utc_today().year,
                "Quarter" => 1
              }
            ]

          String.ends_with?(conn.request_path, "/live/wallstreetbets") ->
            [
              %{
                "Ticker" => "GME",
                "Mentions" => 700,
                "PreviousMentions" => 300,
                "Sentiment" => 0.8,
                "Date" => today
              }
            ]

          true ->
            []
        end

      Req.Test.json(conn, body)
    end)

    :ok
  end

  test "all five providers boot, poll, and write to SignalStore" do
    # Application may have already started AltData.Supervisor with quiver disabled
    # (env wasn't set yet). Restart it under the application supervisor so it
    # re-evaluates enabled_providers/0 with our setup env in place.
    old_pid = Process.whereis(AlpacaTrader.AltData.Supervisor)

    if old_pid do
      ref = Process.monitor(old_pid)
      Process.exit(old_pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^old_pid, _} -> :ok
      after
        2_000 -> flunk("AltData.Supervisor failed to terminate")
      end
    end

    # Wait for the application supervisor (one_for_one) to restart AltData.Supervisor.
    new_sup =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        case Process.whereis(AlpacaTrader.AltData.Supervisor) do
          nil ->
            Process.sleep(20)
            {:cont, nil}

          pid when pid != old_pid ->
            {:halt, pid}

          _ ->
            Process.sleep(20)
            {:cont, nil}
        end
      end)

    assert is_pid(new_sup), "AltData.Supervisor did not restart"

    # Wait for all 5 quiver provider children to be registered.
    :ok =
      Enum.reduce_while(1..50, :pending, fn _, _ ->
        if Enum.all?(@quiver_providers, &is_pid(Process.whereis(&1))) do
          {:halt, :ok}
        else
          Process.sleep(20)
          {:cont, :pending}
        end
      end)

    # Allow each supervised provider GenServer to use the test process's Req.Test stub,
    # then force an immediate poll.
    for mod <- @quiver_providers do
      pid = Process.whereis(mod)
      assert is_pid(pid), "expected #{inspect(mod)} to be running under supervisor"
      Req.Test.allow(@plug, self(), pid)
      send(pid, :poll)
    end

    # Allow async polls to complete.
    Process.sleep(500)

    providers =
      SignalStore.status()
      |> Enum.map(fn {p, _, _} -> p end)
      |> Enum.sort()

    assert :quiver_congress in providers
    assert :quiver_insider in providers
    assert :quiver_govcontracts in providers
    assert :quiver_lobbying in providers
    assert :quiver_wsb in providers
    assert length(SignalStore.all_active()) >= 5
  end
end
