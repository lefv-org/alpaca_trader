defmodule AlpacaTrader.AltData.Providers.QuiverWsb do
  @moduledoc "WallStreetBets mention + sentiment feed."

  use AlpacaTrader.AltData.Provider

  alias AlpacaTrader.AltData.Quiver.{Client, Parser}

  @impl true
  def provider_id, do: :quiver_wsb

  @impl true
  def poll_interval_ms do
    :timer.seconds(Application.get_env(:alpaca_trader, :quiver_wsb_poll_s, 450))
  end

  @impl true
  def fetch do
    case Application.get_env(:alpaca_trader, :quiverquant_api_key) do
      nil ->
        {:ok, []}

      "" ->
        {:ok, []}

      _ ->
        case Client.get("/live/wallstreetbets") do
          {:ok, rows} when is_list(rows) ->
            {:ok, Parser.parse_wsb(rows, DateTime.utc_now())}

          {:ok, _other} ->
            {:error, :unexpected_payload}

          {:error, _} = err ->
            err
        end
    end
  end
end
