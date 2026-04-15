defmodule AlpacaTrader.AltData.Providers.NasaFirms do
  @moduledoc """
  NASA FIRMS wildfire detection provider.
  Detects active fires in agricultural and energy regions.
  Requires free MAP_KEY from https://firms.modaps.eosdis.nasa.gov/api/area/

  Set NASA_FIRMS_MAP_KEY env var and ALT_DATA_NASA_FIRMS_ENABLED=true.
  """

  use AlpacaTrader.AltData.Provider

  alias AlpacaTrader.AltData.Signal

  @base_url "https://firms.modaps.eosdis.nasa.gov/api/area/csv"

  # Regions to monitor: {name, bbox (west,south,east,north), affected_symbols}
  @regions [
    {"California", "-124,32,-114,42", ["PCG", "EIX", "WY"], :energy},
    {"PNW_Forests", "-125,42,-116,49", ["WY", "LPX"], :timber},
    {"Gulf_Energy", "-98,26,-88,31", ["XOM", "CVX", "VLO", "XLE"], :energy},
    {"Corn_Belt", "-96,38,-84,44", ["CORN", "SOYB", "DBA"], :agriculture},
    {"Brazil_Soy", "-60,-20,-44,-5", ["SOYB", "DBA"], :agriculture}
  ]

  @impl true
  def provider_id, do: :nasa_firms

  @impl true
  def poll_interval_ms, do: :timer.hours(12)

  @impl true
  def fetch do
    map_key = Application.get_env(:alpaca_trader, :nasa_firms_map_key)

    if map_key do
      results =
        Enum.map(@regions, fn {name, bbox, symbols, type} ->
          {name, bbox, symbols, type, fetch_region(map_key, bbox)}
        end)

      if Enum.all?(results, fn {_, _, _, _, r} -> match?({:error, _}, r) end) do
        {_, _, _, _, {:error, reason}} = List.first(results)
        {:error, reason}
      else
        signals =
          Enum.flat_map(results, fn {name, _, symbols, type, result} ->
            case result do
              {:ok, count} when count > 0 -> [build_signal(name, count, symbols, type)]
              _ -> []
            end
          end)

        {:ok, signals}
      end
    else
      {:ok, []}
    end
  end

  defp fetch_region(map_key, bbox) do
    today = Date.utc_today() |> Date.to_iso8601()
    url = "#{@base_url}/#{map_key}/VIIRS_SNPP_NRT/#{bbox}/1/#{today}"

    case Req.get(Req.new(), url: url, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        lines = body |> String.split("\n") |> Enum.drop(1) |> Enum.reject(&(&1 == ""))
        {:ok, length(lines)}

      {:ok, %{status: s}} ->
        {:error, "FIRMS status=#{s}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_signal(region, fire_count, symbols, type) do
    {direction, strength} =
      cond do
        fire_count > 500 -> {:bullish, 0.9}
        fire_count > 100 -> {:bullish, 0.7}
        fire_count > 20 -> {:bullish, 0.5}
        true -> {:neutral, 0.3}
      end

    reason =
      case type do
        :agriculture -> "#{fire_count} fires in #{region} — crop/agricultural supply risk"
        :timber -> "#{fire_count} fires in #{region} — lumber supply disruption"
        :energy -> "#{fire_count} fires in #{region} — energy infrastructure risk"
      end

    %Signal{
      provider: :nasa_firms,
      signal_type: :wildfire,
      direction: direction,
      strength: strength,
      affected_symbols: symbols,
      reason: reason,
      fetched_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 26, :hour),
      raw: %{region: region, fire_count: fire_count, type: type}
    }
  end
end
