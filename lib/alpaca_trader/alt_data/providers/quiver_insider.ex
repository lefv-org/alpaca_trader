defmodule AlpacaTrader.AltData.Providers.QuiverInsider do
  @moduledoc "Form-4 corporate insider filings."

  use AlpacaTrader.AltData.Provider

  alias AlpacaTrader.AltData.Quiver.{Client, Parser}

  @impl true
  def provider_id, do: :quiver_insider

  @impl true
  def poll_interval_ms do
    :timer.seconds(Application.get_env(:alpaca_trader, :quiver_insider_poll_s, 900))
  end

  @impl true
  def fetch do
    case Application.get_env(:alpaca_trader, :quiverquant_api_key) do
      nil ->
        {:ok, []}

      "" ->
        {:ok, []}

      _ ->
        lookback = Application.get_env(:alpaca_trader, :quiver_insider_lookback_d, 30)

        case Client.get("/live/insiders") do
          {:ok, rows} when is_list(rows) ->
            {:ok, Parser.parse_insider(rows, DateTime.utc_now(), lookback)}

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
