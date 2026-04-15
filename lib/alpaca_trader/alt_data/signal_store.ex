defmodule AlpacaTrader.AltData.SignalStore do
  @moduledoc """
  ETS-backed store for alternative data signals.
  One row per provider, replaced atomically on each poll.
  TTL filtering on reads — stale signals are silently ignored.
  """

  use GenServer

  @table :alt_data_signals

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Replace all signals for a provider."
  def put(provider, signals) when is_atom(provider) and is_list(signals) do
    :ets.insert(@table, {provider, signals, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc "All non-expired signals across all providers."
  def all_active do
    now = DateTime.utc_now()

    @table
    |> :ets.tab2list()
    |> Enum.flat_map(fn {_provider, signals, _inserted_ms} ->
      Enum.filter(signals, fn sig ->
        sig.expires_at == nil or DateTime.compare(sig.expires_at, now) == :gt
      end)
    end)
  end

  @doc "Active signals affecting a specific symbol."
  def active_for(symbol) when is_binary(symbol) do
    all_active()
    |> Enum.filter(fn sig ->
      symbol in (sig.affected_symbols || [])
    end)
  end

  @doc "Provider status for diagnostics."
  def status do
    now_ms = System.monotonic_time(:millisecond)

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {provider, signals, inserted_ms} ->
      age_s = div(now_ms - inserted_ms, 1000)
      {provider, length(signals), age_s}
    end)
  end

  @impl GenServer
  def init(_) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end
end
