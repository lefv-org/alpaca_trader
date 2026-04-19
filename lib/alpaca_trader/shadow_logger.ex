defmodule AlpacaTrader.ShadowLogger do
  @moduledoc """
  Append-only JSONL log of every entry/exit *signal* the engine generates,
  including gate rejections.

  Purpose: detect silent drift when live fills diverge from intended engine
  activity. Writes to `priv/runtime/shadow_signals.jsonl` by default; path
  configurable via `:alpaca_trader, :shadow_log_path`.

  The engine calls `record_signal/1` at each decision point when the
  `:shadow_mode_enabled` application flag is true (default false).

  Signals are buffered in-memory and written to disk on `flush/0`. In-memory
  counters by status are always maintained and exposed via `summary/0`.

  ## Signal shape

      %{
        timestamp: DateTime.t(),
        pair: String.t(),
        event: :entry_signal | :exit_signal,
        status: :would_enter | :would_exit | :blocked | :filled | :rejected,
        z_score: float(),
        gate_rejections: [atom()] | nil
      }
  """

  use GenServer
  require Logger

  @type status :: :would_enter | :would_exit | :blocked | :filled | :rejected

  @type signal :: %{
          required(:timestamp) => DateTime.t(),
          required(:pair) => String.t(),
          required(:event) => :entry_signal | :exit_signal,
          required(:status) => status(),
          required(:z_score) => float(),
          optional(:gate_rejections) => [atom()]
        }

  @default_path "priv/runtime/shadow_signals.jsonl"

  # ── Client API ─────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Record a signal. Fire-and-forget (cast). Counters update immediately;
  bytes reach disk on the next `flush/0`.
  """
  def record_signal(%{} = signal, server \\ __MODULE__) do
    GenServer.cast(server, {:record, signal})
  end

  @doc "Flush buffered signals to disk (append)."
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush)

  @doc "Return in-memory counters keyed by status atom."
  def summary(server \\ __MODULE__), do: GenServer.call(server, :summary)

  # ── GenServer callbacks ────────────────────────────────────

  @impl true
  def init(opts) do
    path = opts[:path] || Application.get_env(:alpaca_trader, :shadow_log_path, @default_path)
    File.mkdir_p!(Path.dirname(path))
    {:ok, %{path: path, buffer: [], counters: %{}}}
  end

  @impl true
  def handle_cast({:record, signal}, state) do
    line = Jason.encode!(signal) <> "\n"
    key = signal[:status]
    new_counters = Map.update(state.counters, key, 1, &(&1 + 1))
    {:noreply, %{state | buffer: [line | state.buffer], counters: new_counters}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    case state.buffer do
      [] ->
        {:reply, :ok, state}

      buf ->
        File.write!(state.path, Enum.reverse(buf), [:append])
        {:reply, :ok, %{state | buffer: []}}
    end
  end

  def handle_call(:summary, _from, state), do: {:reply, state.counters, state}
end
