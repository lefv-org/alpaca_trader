defmodule AlpacaTrader.AltData.Providers.QuiverGovContracts do
  @moduledoc "Federal contract awards aggregated per ticker."

  use AlpacaTrader.AltData.Provider

  alias AlpacaTrader.AltData.Quiver.{Client, Parser}

  @impl true
  def provider_id, do: :quiver_govcontracts

  @impl true
  def poll_interval_ms do
    :timer.seconds(Application.get_env(:alpaca_trader, :quiver_govcontracts_poll_s, 10_800))
  end

  @impl true
  def fetch do
    case Application.get_env(:alpaca_trader, :quiverquant_api_key) do
      nil ->
        {:ok, []}

      "" ->
        {:ok, []}

      _ ->
        lookback = Application.get_env(:alpaca_trader, :quiver_govcontracts_lookback_d, 30)

        case Client.get("/live/govcontractsall") do
          {:ok, rows} when is_list(rows) ->
            {:ok, Parser.parse_govcontracts(rows, DateTime.utc_now(), lookback)}

          {:ok, _other} ->
            {:error, :unexpected_payload}

          {:error, _} = err ->
            err
        end
    end
  end

  @impl GenServer
  def init(_) do
    jitter_ms = :rand.uniform(max(1, div(poll_interval_ms(), 4)))
    Process.send_after(self(), :poll, jitter_ms)
    {:ok, %{consecutive_errors: 0}}
  end
end
