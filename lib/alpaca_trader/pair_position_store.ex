defmodule AlpacaTrader.PairPositionStore do
  @moduledoc """
  ETS-backed store for tracking open pair trade positions.
  Tracks entry state, current z-score, P&L, and exit thresholds.
  """

  use GenServer

  @table :pair_position_store

  defmodule PairPosition do
    @moduledoc "An open pair trade being tracked for exit conditions."
    @derive Jason.Encoder
    defstruct [
      :id,
      :asset_a,
      :asset_b,
      :direction,
      :tier,

      # Entry state
      :entry_z_score,
      :entry_hedge_ratio,
      :entry_price_a,
      :entry_price_b,
      :entry_time,

      # Current state
      :current_z_score,
      :bars_held,
      :last_updated,

      # Thresholds
      :exit_z_threshold,
      :stop_z_threshold,
      :max_hold_bars,
      :status
    ]
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Open a new pair position."
  def open_position(attrs) when is_map(attrs) do
    id = "#{attrs.asset_a}-#{attrs.asset_b}-#{System.system_time(:second)}"

    pos = %PairPosition{
      id: id,
      asset_a: attrs.asset_a,
      asset_b: attrs.asset_b,
      direction: attrs.direction,
      tier: attrs.tier,
      entry_z_score: attrs.z_score,
      entry_hedge_ratio: attrs.hedge_ratio,
      entry_price_a: attrs[:entry_price_a],
      entry_price_b: attrs[:entry_price_b],
      entry_time: DateTime.utc_now(),
      current_z_score: attrs.z_score,
      bars_held: 0,
      last_updated: DateTime.utc_now(),
      exit_z_threshold: if(attrs.tier == 2, do: 0.5, else: 0.75),
      stop_z_threshold: if(attrs.tier == 2, do: 4.0, else: 5.0),
      max_hold_bars: if(attrs.tier == 2, do: 20, else: 30),
      status: :open
    }

    :ets.insert(@table, {id, pos})
    {:ok, pos}
  end

  @doc "Find an open position involving this asset."
  def find_open_for_asset(asset) do
    @table
    |> :ets.tab2list()
    |> Enum.find_value(fn {_id, pos} ->
      if pos.status == :open and (pos.asset_a == asset or pos.asset_b == asset) do
        pos
      end
    end)
  end

  @doc "Update the current z-score and increment bars_held for a position."
  def tick(id, current_z_score) do
    case :ets.lookup(@table, id) do
      [{^id, %PairPosition{} = pos}] ->
        updated = %PairPosition{
          pos
          | current_z_score: current_z_score,
            bars_held: pos.bars_held + 1,
            last_updated: DateTime.utc_now()
        }

        :ets.insert(@table, {id, updated})
        {:ok, updated}

      [] ->
        :error
    end
  end

  @doc "Close a position (mark as closed)."
  def close_position(id) do
    case :ets.lookup(@table, id) do
      [{^id, %PairPosition{} = pos}] ->
        closed = %PairPosition{pos | status: :closed, last_updated: DateTime.utc_now()}
        :ets.insert(@table, {id, closed})
        {:ok, closed}

      [] ->
        :error
    end
  end

  @doc "List all open positions."
  def open_positions do
    @table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(&1.status == :open))
  end

  @doc "Count of open positions."
  def open_count do
    length(open_positions())
  end

  @doc "Clear all positions (for testing)."
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  # GenServer callbacks

  @impl true
  def init(_) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end
end
