defmodule AlpacaTrader.AltData.Providers.Fred do
  @moduledoc """
  Federal Reserve Economic Data (FRED) provider.
  Tracks yield curve (T10Y2Y), high-yield credit spread (BAMLH0A0HYM2),
  and weekly jobless claims (ICSA) for macro regime detection.

  No API key required for public series.
  """

  use AlpacaTrader.AltData.Provider

  alias AlpacaTrader.AltData.Signal

  @base_url "https://api.stlouisfed.org/fred/series/observations"
  @series %{
    "T10Y2Y" => {:yield_curve, "10Y-2Y Treasury spread"},
    "BAMLH0A0HYM2" => {:credit_spread, "High-yield credit spread"},
    "ICSA" => {:jobless_claims, "Initial jobless claims"}
  }

  @impl true
  def provider_id, do: :fred

  @impl true
  def poll_interval_ms, do: :timer.hours(6)

  @impl true
  def fetch do
    api_key = Application.get_env(:alpaca_trader, :fred_api_key, "DEMO_KEY")

    results =
      Enum.map(Map.keys(@series), fn series_id ->
        {series_id, fetch_series(series_id, api_key)}
      end)

    # If all series failed, propagate an error so backoff kicks in
    if Enum.all?(results, fn {_, r} -> match?({:error, _}, r) end) do
      {_, {:error, reason}} = List.first(results)
      {:error, reason}
    else
      signals =
        Enum.flat_map(results, fn {series_id, result} ->
          {type, label} = @series[series_id]
          case result do
            {:ok, value} -> [build_signal(type, label, series_id, value)]
            {:error, _} -> []
          end
        end)

      {:ok, signals}
    end
  end

  defp fetch_series(series_id, api_key) do
    params = [
      series_id: series_id,
      api_key: api_key,
      file_type: "json",
      sort_order: "desc",
      limit: 1
    ]

    case Req.get(Req.new(), url: @base_url, params: params, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"observations" => [%{"value" => val} | _]}}} when val != "." ->
        {:ok, String.to_float(val)}

      {:ok, %{status: status, body: body}} ->
        {:error, "FRED #{series_id} status=#{status}: #{inspect(body) |> String.slice(0..80)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_signal(:yield_curve, label, series_id, value) do
    {direction, strength} =
      cond do
        value < -0.5 -> {:risk_off, min(abs(value) / 2.0, 1.0)}
        value < 0 -> {:risk_off, 0.4}
        value < 0.5 -> {:neutral, 0.2}
        true -> {:risk_on, min(value / 3.0, 0.8)}
      end

    %Signal{
      provider: :fred,
      signal_type: :macro_regime,
      direction: direction,
      strength: strength,
      affected_symbols: ["SPY", "QQQ", "TLT", "IWM", "HYG"],
      reason: "#{label}: #{value} (#{direction})",
      fetched_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 14, :hour),
      raw: %{series_id: series_id, value: value}
    }
  end

  defp build_signal(:credit_spread, label, series_id, value) do
    {direction, strength} =
      cond do
        value > 6.0 -> {:risk_off, 0.9}
        value > 4.5 -> {:risk_off, 0.7}
        value > 3.5 -> {:bearish, 0.5}
        value < 2.5 -> {:risk_on, 0.6}
        true -> {:neutral, 0.2}
      end

    %Signal{
      provider: :fred,
      signal_type: :macro_regime,
      direction: direction,
      strength: strength,
      affected_symbols: ["HYG", "JNK", "SPY", "IWM"],
      reason: "#{label}: #{value}% (#{direction})",
      fetched_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 14, :hour),
      raw: %{series_id: series_id, value: value}
    }
  end

  defp build_signal(:jobless_claims, label, series_id, value) do
    {direction, strength} =
      cond do
        value > 350_000 -> {:risk_off, 0.8}
        value > 300_000 -> {:bearish, 0.5}
        value < 200_000 -> {:risk_on, 0.6}
        true -> {:neutral, 0.2}
      end

    %Signal{
      provider: :fred,
      signal_type: :macro_regime,
      direction: direction,
      strength: strength,
      affected_symbols: ["SPY", "QQQ", "XLF", "TLT"],
      reason: "#{label}: #{trunc(value)} (#{direction})",
      fetched_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 14, :hour),
      raw: %{series_id: series_id, value: value}
    }
  end
end
