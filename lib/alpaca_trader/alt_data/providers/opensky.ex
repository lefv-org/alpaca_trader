defmodule AlpacaTrader.AltData.Providers.OpenSky do
  @moduledoc """
  OpenSky Network flight tracking provider.
  Counts aircraft in US airspace as an economic activity proxy.
  Maintains a rolling history to detect anomalies.

  Standalone GenServer (not using Provider macro) because it needs
  custom state for the rolling mean calculation.
  """

  use GenServer
  require Logger

  alias AlpacaTrader.AltData.Signal

  @base_url "https://opensky-network.org/api/states/all"
  @bbox [lamin: 25, lamax: 49, lomin: -125, lomax: -65]
  @history_size 96
  @max_backoff_ms :timer.minutes(30)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_) do
    send(self(), :poll)
    {:ok, %{consecutive_errors: 0, history: []}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    new_state =
      try do
        case fetch_count() do
          {:ok, count} ->
            history = Enum.take([count | state.history], @history_size)
            signals = analyze(count, history)
            AlpacaTrader.AltData.SignalStore.put(:opensky, signals)

            if signals != [] do
              Logger.info("[AltData:opensky] #{count} aircraft, #{length(signals)} signals")
            end

            %{state | consecutive_errors: 0, history: history}

          {:error, reason} ->
            errors = state.consecutive_errors + 1

            Logger.warning(
              "[AltData:opensky] fetch failed (#{errors}x): #{inspect(reason) |> String.slice(0..80)}"
            )

            %{state | consecutive_errors: errors}
        end
      rescue
        e ->
          errors = state.consecutive_errors + 1
          Logger.warning("[AltData:opensky] crash (#{errors}x): #{Exception.message(e)}")
          %{state | consecutive_errors: errors}
      end

    interval = backoff_interval(new_state.consecutive_errors)
    Process.send_after(self(), :poll, interval)
    {:noreply, new_state}
  end

  defp poll_interval_ms do
    :timer.seconds(Application.get_env(:alpaca_trader, :alt_data_opensky_poll_s, 900))
  end

  defp backoff_interval(0), do: poll_interval_ms()

  defp backoff_interval(errors) do
    backed_off = (poll_interval_ms() * :math.pow(2, min(errors, 8))) |> trunc()
    min(backed_off, @max_backoff_ms)
  end

  defp fetch_count do
    case Req.get(Req.new(), url: @base_url, params: @bbox, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"states" => states}}} when is_list(states) ->
        {:ok, length(states)}

      {:ok, %{status: 200, body: %{"states" => nil}}} ->
        {:ok, 0}

      {:ok, %{status: s}} ->
        {:error, "opensky status=#{s}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp analyze(_count, history) when length(history) < 8, do: []

  defp analyze(count, history) do
    mean = Enum.sum(history) / length(history)
    variance = Enum.sum(Enum.map(history, fn x -> :math.pow(x - mean, 2) end)) / length(history)
    std_dev = :math.sqrt(variance)

    if std_dev == 0, do: [], else: build_signals(count, mean, std_dev)
  end

  defp build_signals(count, mean, std_dev) do
    z = (count - mean) / std_dev

    cond do
      z < -2.0 ->
        [
          %Signal{
            provider: :opensky,
            signal_type: :cargo_volume,
            direction: :bearish,
            strength: min(abs(z) / 4.0, 1.0),
            affected_symbols: ["DAL", "UAL", "AAL", "FDX", "UPS", "IYT"],
            reason: "Flight count #{count} is #{Float.round(z, 1)}σ below mean #{trunc(mean)}",
            fetched_at: DateTime.utc_now(),
            expires_at: DateTime.add(DateTime.utc_now(), 35, :minute),
            raw: %{count: count, mean: mean, z_score: z}
          }
        ]

      z > 2.0 ->
        [
          %Signal{
            provider: :opensky,
            signal_type: :cargo_volume,
            direction: :bullish,
            strength: min(z / 4.0, 1.0),
            affected_symbols: ["DAL", "UAL", "AAL", "FDX", "UPS", "IYT"],
            reason: "Flight count #{count} is +#{Float.round(z, 1)}σ above mean #{trunc(mean)}",
            fetched_at: DateTime.utc_now(),
            expires_at: DateTime.add(DateTime.utc_now(), 35, :minute),
            raw: %{count: count, mean: mean, z_score: z}
          }
        ]

      true ->
        []
    end
  end
end
