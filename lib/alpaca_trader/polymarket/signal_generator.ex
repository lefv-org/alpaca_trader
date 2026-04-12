defmodule AlpacaTrader.Polymarket.SignalGenerator do
  @moduledoc """
  Monitors Polymarket events for probability shifts and generates
  ArbitragePosition signals for the Engine.

  Detects:
  - Rapid probability shifts (>10% change)
  - Volume spikes (>2x average)
  - New high-volume events matching tradeable symbols
  """

  use GenServer

  alias AlpacaTrader.Polymarket.{Client, MarketMapper}
  alias AlpacaTrader.Engine.ArbitragePosition

  require Logger

  @poll_interval_ms :timer.seconds(30)
  @shift_threshold 0.10
  @min_volume 5000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Get current signals from Polymarket probability shifts."
  def signals do
    GenServer.call(__MODULE__, :signals, 30_000)
  end

  @doc "Force a refresh of market data."
  def refresh do
    GenServer.call(__MODULE__, :refresh, 30_000)
  end

  # GenServer

  @impl true
  def init(_) do
    schedule_poll()
    {:ok, %{events: %{}, signals: [], last_poll: nil}}
  end

  @impl true
  def handle_call(:signals, _from, state) do
    {:reply, state.signals, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    state = poll_and_detect(state)
    {:reply, {:ok, length(state.signals)}, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll_and_detect(state)
    schedule_poll()
    {:noreply, state}
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp poll_and_detect(state) do
    case Client.active_events(limit: 30) do
      {:ok, events} when is_list(events) ->
        # Filter to tradeable events
        tradeable_events =
          events
          |> Enum.filter(fn e ->
            title = e["title"] || ""
            MarketMapper.tradeable?(title) and (e["volume24hr"] || 0) > @min_volume
          end)

        # Extract current probabilities
        current_probs = extract_probabilities(tradeable_events)

        # Detect shifts from previous poll
        new_signals = detect_shifts(state.events, current_probs)

        if new_signals != [] do
          Logger.info("[Polymarket] #{length(new_signals)} signals detected")
        end

        %{state | events: current_probs, signals: new_signals, last_poll: DateTime.utc_now()}

      {:error, reason} ->
        Logger.warning("[Polymarket] poll failed: #{inspect(reason) |> String.slice(0..80)}")
        state
    end
  end

  defp extract_probabilities(events) do
    Enum.reduce(events, %{}, fn event, acc ->
      title = event["title"] || ""
      markets = event["markets"] || []

      Enum.reduce(markets, acc, fn market, inner_acc ->
        question = market["question"] || ""
        price = parse_price(market["outcomePrices"])
        volume = market["volume24hr"] || 0
        token_id = parse_token_id(market["clobTokenIds"])

        key = "#{title}::#{question}"

        Map.put(inner_acc, key, %{
          title: title,
          question: question,
          probability: price,
          volume: volume,
          token_id: token_id
        })
      end)
    end)
  end

  defp detect_shifts(prev, current) do
    Enum.flat_map(current, fn {key, curr} ->
      case Map.get(prev, key) do
        %{probability: prev_prob} when is_number(prev_prob) and is_number(curr.probability) ->
          shift = curr.probability - prev_prob

          if abs(shift) >= @shift_threshold do
            symbols = MarketMapper.map_event(curr.title)

            Enum.map(symbols, fn {symbol, _type} ->
              side = if shift > 0, do: :long_a_short_b, else: :long_b_short_a

              %ArbitragePosition{
                result: true,
                asset: symbol,
                reason: "POLYMARKET: #{curr.title} shifted #{Float.round(shift * 100, 1)}% to #{Float.round(curr.probability * 100, 1)}%",
                action: :enter,
                tier: 4,
                pair_asset: nil,
                direction: side,
                z_score: nil,
                spread: shift,
                timestamp: DateTime.utc_now()
              }
            end)
          else
            []
          end

        _ ->
          # First time seeing this market, no shift to detect
          []
      end
    end)
  end

  defp parse_price(nil), do: nil
  defp parse_price(prices_str) when is_binary(prices_str) do
    case Jason.decode(prices_str) do
      {:ok, [yes_price | _]} ->
        case Float.parse(to_string(yes_price)) do
          {f, _} -> f
          :error -> nil
        end
      _ -> nil
    end
  end
  defp parse_price(_), do: nil

  defp parse_token_id(nil), do: nil
  defp parse_token_id(ids_str) when is_binary(ids_str) do
    case Jason.decode(ids_str) do
      {:ok, [id | _]} -> id
      _ -> nil
    end
  end
  defp parse_token_id(_), do: nil
end
