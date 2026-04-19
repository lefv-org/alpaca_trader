defmodule AlpacaTrader.AltData.Providers.Finnhub do
  @moduledoc """
  Finnhub social sentiment and news provider.
  Requires free API key from https://finnhub.io/

  Set FINNHUB_API_KEY env var and ALT_DATA_FINNHUB_ENABLED=true.
  """

  use AlpacaTrader.AltData.Provider

  alias AlpacaTrader.AltData.Signal

  @base_url "https://finnhub.io/api/v1"

  @impl true
  def provider_id, do: :finnhub

  @impl true
  def poll_interval_ms do
    :timer.seconds(Application.get_env(:alpaca_trader, :alt_data_finnhub_poll_s, 300))
  end

  @impl true
  def fetch do
    api_key = Application.get_env(:alpaca_trader, :finnhub_api_key)

    if api_key do
      case fetch_market_news(api_key) do
        {:ok, signals} -> {:ok, signals}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, []}
    end
  end

  defp fetch_market_news(api_key) do
    case Req.get(Req.new(),
           url: "#{@base_url}/news",
           params: [category: "general", token: api_key],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: articles}} when is_list(articles) ->
        signals = analyze_headlines(articles)
        {:ok, signals}

      {:ok, %{status: s}} ->
        {:error, "finnhub status=#{s}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp analyze_headlines(articles) do
    # Count bearish vs bullish keyword density in recent headlines
    recent = Enum.take(articles, 20)

    bearish_keywords = ~w(crash recession layoff bankruptcy default tariff sanctions war shutdown)
    bullish_keywords = ~w(surge rally record growth boom expansion hiring deal merger)

    {bearish_count, bullish_count} =
      Enum.reduce(recent, {0, 0}, fn article, {bear, bull} ->
        headline = String.downcase(article["headline"] || "")
        summary = String.downcase(article["summary"] || "")
        text = headline <> " " <> summary

        bear_hits = Enum.count(bearish_keywords, &String.contains?(text, &1))
        bull_hits = Enum.count(bullish_keywords, &String.contains?(text, &1))

        {bear + bear_hits, bull + bull_hits}
      end)

    total = bearish_count + bullish_count
    if total < 3, do: [], else: build_sentiment_signal(bearish_count, bullish_count, total)
  end

  defp build_sentiment_signal(bearish, bullish, total) do
    ratio = bullish / total

    {direction, strength} =
      cond do
        ratio < 0.25 -> {:bearish, 0.7}
        ratio < 0.35 -> {:bearish, 0.5}
        ratio > 0.75 -> {:bullish, 0.7}
        ratio > 0.65 -> {:bullish, 0.5}
        true -> {:neutral, 0.2}
      end

    if direction == :neutral do
      []
    else
      [
        %Signal{
          provider: :finnhub,
          signal_type: :sentiment,
          direction: direction,
          strength: strength,
          affected_symbols: ["SPY", "QQQ", "IWM"],
          reason:
            "News sentiment #{direction}: #{bullish} bullish vs #{bearish} bearish keywords in #{total} mentions",
          fetched_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), 12, :minute),
          raw: %{bullish: bullish, bearish: bearish, ratio: ratio}
        }
      ]
    end
  end
end
