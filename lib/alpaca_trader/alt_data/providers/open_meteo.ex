defmodule AlpacaTrader.AltData.Providers.OpenMeteo do
  @moduledoc """
  Open-Meteo weather provider. No API key required.
  Tracks temperature extremes and precipitation for agricultural
  commodity and energy demand signals.
  """

  use AlpacaTrader.AltData.Provider

  alias AlpacaTrader.AltData.Signal

  @base_url "https://api.open-meteo.com/v1/forecast"

  # Key agricultural/energy locations
  @locations [
    # Corn Belt
    %{
      name: "Iowa",
      lat: 42.03,
      lon: -93.65,
      type: :agriculture,
      symbols: ["CORN", "SOYB", "DBA"]
    },
    # Wheat Belt
    %{name: "Kansas", lat: 38.50, lon: -98.77, type: :agriculture, symbols: ["WEAT", "DBA"]},
    # Energy demand (population centers)
    %{name: "Chicago", lat: 41.88, lon: -87.63, type: :energy, symbols: ["UNG", "XLE", "XLU"]},
    %{name: "Houston", lat: 29.76, lon: -95.37, type: :energy, symbols: ["XOM", "CVX", "XLE"]}
  ]

  @impl true
  def provider_id, do: :open_meteo

  @impl true
  def poll_interval_ms, do: :timer.hours(4)

  @impl true
  def fetch do
    results = Enum.map(@locations, fn loc -> {loc, fetch_forecast(loc)} end)

    if Enum.all?(results, fn {_, r} -> match?({:error, _}, r) end) do
      {_, {:error, reason}} = List.first(results)
      {:error, reason}
    else
      signals =
        Enum.flat_map(results, fn {loc, result} ->
          case result do
            {:ok, data} -> analyze_forecast(loc, data)
            {:error, _} -> []
          end
        end)

      {:ok, signals}
    end
  end

  defp fetch_forecast(loc) do
    params = [
      latitude: loc.lat,
      longitude: loc.lon,
      daily: "temperature_2m_max,temperature_2m_min,precipitation_sum",
      temperature_unit: "fahrenheit",
      precipitation_unit: "inch",
      timezone: "America/Chicago",
      forecast_days: 7
    ]

    case Req.get(Req.new(), url: @base_url, params: params, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: s}} -> {:error, "open-meteo status=#{s}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp analyze_forecast(loc, %{"daily" => daily}) do
    temps_max = daily["temperature_2m_max"] || []
    temps_min = daily["temperature_2m_min"] || []
    precip = daily["precipitation_sum"] || []

    max_temp = Enum.max(temps_max, fn -> 0 end)
    min_temp = Enum.min(temps_min, fn -> 70 end)
    total_precip = Enum.sum(precip)
    now = DateTime.utc_now()
    expires = DateTime.add(now, 10, :hour)

    []
    |> maybe_heat_signal(loc, max_temp, now, expires)
    |> maybe_cold_signal(loc, min_temp, now, expires)
    |> maybe_flood_signal(loc, total_precip, now, expires)
    |> maybe_drought_signal(loc, total_precip, max_temp, now, expires)
  end

  defp analyze_forecast(_loc, _data), do: []

  defp maybe_heat_signal(signals, %{type: :agriculture} = loc, max_temp, now, expires)
       when max_temp > 100 do
    [
      %Signal{
        provider: :open_meteo,
        signal_type: :weather,
        direction: :bullish,
        strength: min((max_temp - 95) / 20.0, 1.0),
        affected_symbols: loc.symbols,
        reason: "Extreme heat #{loc.name}: #{max_temp}°F — crop stress",
        fetched_at: now,
        expires_at: expires,
        raw: %{location: loc.name, max_temp: max_temp, type: :heat_stress}
      }
      | signals
    ]
  end

  defp maybe_heat_signal(signals, _, _, _, _), do: signals

  defp maybe_cold_signal(signals, %{type: :energy} = loc, min_temp, now, expires)
       when min_temp < 10 do
    [
      %Signal{
        provider: :open_meteo,
        signal_type: :weather,
        direction: :bullish,
        strength: min((32 - min_temp) / 40.0, 1.0),
        affected_symbols: loc.symbols,
        reason: "Extreme cold #{loc.name}: #{min_temp}°F — heating demand spike",
        fetched_at: now,
        expires_at: expires,
        raw: %{location: loc.name, min_temp: min_temp, type: :cold_demand}
      }
      | signals
    ]
  end

  defp maybe_cold_signal(signals, _, _, _, _), do: signals

  defp maybe_flood_signal(signals, %{type: :agriculture} = loc, precip, now, expires)
       when precip > 4.0 do
    [
      %Signal{
        provider: :open_meteo,
        signal_type: :weather,
        direction: :bullish,
        strength: min(precip / 8.0, 1.0),
        affected_symbols: loc.symbols,
        reason: "Heavy rain #{loc.name}: #{Float.round(precip, 1)}in/7d — flood risk",
        fetched_at: now,
        expires_at: expires,
        raw: %{location: loc.name, precip_7d: precip, type: :flood_risk}
      }
      | signals
    ]
  end

  defp maybe_flood_signal(signals, _, _, _, _), do: signals

  defp maybe_drought_signal(signals, %{type: :agriculture} = loc, precip, max_temp, now, expires)
       when precip < 0.1 and max_temp > 90 do
    [
      %Signal{
        provider: :open_meteo,
        signal_type: :weather,
        direction: :bullish,
        strength: min((max_temp - 85) / 25.0, 0.9),
        affected_symbols: loc.symbols,
        reason: "Drought risk #{loc.name}: 0 rain + #{max_temp}°F — crop yield threat",
        fetched_at: now,
        expires_at: expires,
        raw: %{location: loc.name, precip_7d: precip, max_temp: max_temp, type: :drought}
      }
      | signals
    ]
  end

  defp maybe_drought_signal(signals, _, _, _, _, _), do: signals
end
