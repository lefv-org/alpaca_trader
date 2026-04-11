defmodule AlpacaTrader.AssetStore do
  @moduledoc """
  In-memory store for tradeable assets, backed by ETS.
  Populated by the AssetSyncJob on a recurring schedule.
  """

  use GenServer

  @table :asset_store

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Replace all stored assets."
  def put_assets(assets) when is_list(assets) do
    GenServer.call(__MODULE__, {:put, assets})
  end

  @doc "Get all stored assets."
  def all do
    case :ets.info(@table) do
      :undefined ->
        []

      _ ->
        :ets.tab2list(@table)
        |> Enum.reject(fn {k, _} -> is_atom(k) end)
        |> Enum.map(&elem(&1, 1))
    end
  end

  @doc "Look up a single asset by symbol."
  def get(symbol) do
    case :ets.lookup(@table, symbol) do
      [{^symbol, asset}] -> {:ok, asset}
      [] -> :error
    end
  end

  @doc "Count of stored assets."
  def count do
    length(all())
  end

  @doc "Timestamp of the last successful sync."
  def last_synced_at do
    case :ets.lookup(@table, :__meta_last_synced_at__) do
      [{_, ts}] -> ts
      [] -> nil
    end
  end

  # GenServer callbacks

  @impl true
  def init(_) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, assets}, _from, state) do
    :ets.delete_all_objects(@table)

    Enum.each(assets, fn asset ->
      :ets.insert(@table, {asset["symbol"], asset})
    end)

    :ets.insert(@table, {:__meta_last_synced_at__, DateTime.utc_now()})

    {:reply, :ok, state}
  end
end
