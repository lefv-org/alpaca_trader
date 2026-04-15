defmodule AlpacaTrader.AltData.Providers.Nws do
  @moduledoc """
  National Weather Service alerts provider. No API key needed.
  Monitors hurricane/severe storm alerts for Gulf Coast and Eastern seaboard
  that impact energy infrastructure and insurance.
  """

  use AlpacaTrader.AltData.Provider

  alias AlpacaTrader.AltData.Signal

  @base_url "https://api.weather.gov/alerts/active"

  # States with energy infrastructure and hurricane exposure
  @watch_areas "FL,LA,TX,MS,AL,GA,SC,NC"

  # Severe event types that move markets
  @market_events MapSet.new([
    "Hurricane Warning", "Hurricane Watch",
    "Tropical Storm Warning", "Tropical Storm Watch",
    "Storm Surge Warning", "Storm Surge Watch",
    "Extreme Wind Warning", "Tornado Warning",
    "Flash Flood Emergency", "Ice Storm Warning",
    "Blizzard Warning"
  ])

  @impl true
  def provider_id, do: :nws

  @impl true
  def poll_interval_ms, do: :timer.minutes(30)

  @impl true
  def fetch do
    headers = [{"user-agent", "(alpaca_trader, contact@example.com)"}]

    case Req.get(Req.new(), url: @base_url, params: [area: @watch_areas],
           headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"features" => features}}} ->
        signals =
          features
          |> Enum.filter(fn f ->
            event = get_in(f, ["properties", "event"]) || ""
            MapSet.member?(@market_events, event)
          end)
          |> Enum.map(&alert_to_signal/1)
          |> Enum.uniq_by(fn sig -> sig.reason end)

        {:ok, signals}

      {:ok, %{status: s}} ->
        {:error, "NWS status=#{s}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp alert_to_signal(feature) do
    props = feature["properties"] || %{}
    event = props["event"] || "Unknown"
    severity = props["severity"] || "Unknown"
    areas = props["areaDesc"] || ""
    headline = props["headline"] || event

    is_hurricane = String.contains?(event, "Hurricane")
    is_tropical = String.contains?(event, "Tropical")

    {direction, strength, symbols} =
      cond do
        is_hurricane ->
          {:bearish, 0.9,
           ["XOM", "CVX", "VLO", "PBF", "ALL", "TRV", "CB", "HD", "LOW", "GNRC"]}

        is_tropical ->
          {:bearish, 0.7,
           ["XOM", "CVX", "VLO", "ALL", "TRV"]}

        severity == "Extreme" ->
          {:bearish, 0.8,
           ["XLE", "XLU", "ALL", "TRV"]}

        true ->
          {:bearish, 0.5,
           ["XLE", "XLU"]}
      end

    short_areas = areas |> String.split(";") |> Enum.take(3) |> Enum.join(", ")

    %Signal{
      provider: :nws,
      signal_type: :storm_alert,
      direction: direction,
      strength: strength,
      affected_symbols: symbols,
      reason: "#{event} — #{short_areas}",
      fetched_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 70, :minute),
      raw: %{event: event, severity: severity, headline: headline}
    }
  end
end
