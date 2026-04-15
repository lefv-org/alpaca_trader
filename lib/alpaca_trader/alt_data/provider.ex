defmodule AlpacaTrader.AltData.Provider do
  @moduledoc """
  Behaviour and GenServer macro for alternative data providers.

  Each provider implements three callbacks:
  - `provider_id/0` — atom identifying this provider
  - `poll_interval_ms/0` — how often to fetch (milliseconds)
  - `fetch/0` — HTTP call + normalize to [Signal.t()]

  `use AlpacaTrader.AltData.Provider` injects a GenServer that handles
  scheduling, error backoff, and ETS writes to the SignalStore.
  """

  alias AlpacaTrader.AltData.Signal

  @callback provider_id() :: atom()
  @callback poll_interval_ms() :: pos_integer()
  @callback fetch() :: {:ok, [Signal.t()]} | {:error, term()}

  @max_backoff_ms :timer.minutes(30)

  defmacro __using__(_opts) do
    quote do
      @behaviour AlpacaTrader.AltData.Provider

      use GenServer
      require Logger

      def start_link(_opts) do
        GenServer.start_link(__MODULE__, [], name: __MODULE__)
      end

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          restart: :permanent
        }
      end

      @impl GenServer
      def init(_) do
        send(self(), :poll)
        {:ok, %{consecutive_errors: 0}}
      end

      @impl GenServer
      def handle_info(:poll, state) do
        {signals, new_state} =
          try do
            case fetch() do
              {:ok, signals} when is_list(signals) ->
                AlpacaTrader.AltData.SignalStore.put(provider_id(), signals)
                count = length(signals)
                if count > 0 do
                  Logger.info("[AltData:#{provider_id()}] fetched #{count} signals")
                end
                {signals, %{state | consecutive_errors: 0}}

              {:error, reason} ->
                errors = state.consecutive_errors + 1
                Logger.warning("[AltData:#{provider_id()}] fetch failed (#{errors}x): #{inspect(reason) |> String.slice(0..120)}")
                {[], %{state | consecutive_errors: errors}}
            end
          rescue
            e ->
              errors = state.consecutive_errors + 1
              Logger.warning("[AltData:#{provider_id()}] crash (#{errors}x): #{Exception.message(e)}")
              {[], %{state | consecutive_errors: errors}}
          end

        interval = backoff_interval(new_state.consecutive_errors)
        Process.send_after(self(), :poll, interval)
        {:noreply, new_state}
      end

      defp backoff_interval(0), do: poll_interval_ms()
      defp backoff_interval(errors) do
        backed_off = poll_interval_ms() * :math.pow(2, min(errors, 8)) |> trunc()
        min(backed_off, unquote(@max_backoff_ms))
      end

      defoverridable init: 1
    end
  end
end
