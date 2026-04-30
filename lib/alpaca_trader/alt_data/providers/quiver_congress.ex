defmodule AlpacaTrader.AltData.Providers.QuiverCongress do
  @moduledoc """
  Congressional trade filings (STOCK Act). Polls
  `/bulk/congresstrading` and emits one signal per ticker per
  lookback window.
  """

  use AlpacaTrader.AltData.Provider

  alias AlpacaTrader.AltData.Quiver.{Client, Parser}

  @impl true
  def provider_id, do: :quiver_congress

  @impl true
  def poll_interval_ms do
    :timer.seconds(Application.get_env(:alpaca_trader, :quiver_congress_poll_s, 1800))
  end

  @impl true
  def fetch do
    case Application.get_env(:alpaca_trader, :quiverquant_api_key) do
      nil ->
        {:ok, []}

      "" ->
        {:ok, []}

      _ ->
        lookback = Application.get_env(:alpaca_trader, :quiver_congress_lookback_d, 14)

        case Client.get("/bulk/congresstrading") do
          {:ok, rows} when is_list(rows) ->
            {:ok, Parser.parse_congress(rows, DateTime.utc_now(), lookback)}

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
