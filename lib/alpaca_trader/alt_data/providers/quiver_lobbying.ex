defmodule AlpacaTrader.AltData.Providers.QuiverLobbying do
  @moduledoc "Federal lobbying disclosures."

  use AlpacaTrader.AltData.Provider

  alias AlpacaTrader.AltData.Quiver.{Client, Parser}

  @impl true
  def provider_id, do: :quiver_lobbying

  @impl true
  def poll_interval_ms do
    :timer.seconds(Application.get_env(:alpaca_trader, :quiver_lobbying_poll_s, 43_200))
  end

  @impl true
  def fetch do
    case Application.get_env(:alpaca_trader, :quiverquant_api_key) do
      nil ->
        {:ok, []}

      "" ->
        {:ok, []}

      _ ->
        case Client.get("/live/lobbying") do
          {:ok, rows} when is_list(rows) ->
            {:ok, Parser.parse_lobbying(rows, DateTime.utc_now())}

          {:ok, _other} ->
            {:error, :unexpected_payload}

          {:error, _} = err ->
            err
        end
    end
  end
end
