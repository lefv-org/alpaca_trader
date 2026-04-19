defmodule AlpacaTrader.PairPositionStore do
  @moduledoc """
  ETS-backed store for tracking open pair trade positions, with atomic
  JSON persistence across restarts.

  Tracks entry state, current z-score, P&L, and exit thresholds.

  Persistence: every mutation (`open_position`, `close_position`, `tick`,
  `flip_position`) writes the full state to `priv/runtime/pair_positions.json`
  via tmp+rename. On boot, the same file is loaded back into ETS.

  Without persistence, a crash/restart wiped in-memory pair tracking while
  Alpaca still held the positions — they became "orphans" blocking further
  trades on those symbols. This fix breaks that cycle.
  """

  use GenServer

  require Logger

  @table :pair_position_store
  @default_path "priv/runtime/pair_positions.json"

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
      # OU half-life captured at entry from the spread series (nil if unavailable).
      # Used downstream by HalfLifeManager to set the time-stop bar budget.
      :half_life,

      # Current state
      :current_z_score,
      :bars_held,
      :last_updated,

      # Thresholds
      :exit_z_threshold,
      :stop_z_threshold,
      :max_hold_bars,
      :status,

      # Flip tracking
      flip_count: 0,
      consecutive_losses: 0,
      last_flip_time: nil
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
      half_life: attrs[:half_life],
      current_z_score: attrs.z_score,
      bars_held: 0,
      last_updated: DateTime.utc_now(),
      exit_z_threshold: if(attrs.tier == 2, do: 0.5, else: 0.75),
      stop_z_threshold: if(attrs.tier == 2, do: 4.0, else: 5.0),
      max_hold_bars: if(attrs.tier == 2, do: 20, else: 30),
      status: :open
    }

    :ets.insert(@table, {id, pos})
    persist_async()
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
        persist_async()
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
        persist_async()
        {:ok, closed}

      [] ->
        :error
    end
  end

  @doc "Flip a position: close old, open reversed with flip tracking."
  def flip_position(id, was_profitable) do
    case :ets.lookup(@table, id) do
      [{^id, %PairPosition{} = pos}] ->
        # Close old position
        :ets.insert(@table, {id, %PairPosition{pos | status: :closed}})

        # Open reversed position with flip tracking
        new_consecutive = if was_profitable, do: 0, else: pos.consecutive_losses + 1

        {:ok, new_pos} =
          open_position(%{
            asset_a: pos.asset_a,
            asset_b: pos.asset_b,
            direction: reverse_direction(pos.direction),
            tier: pos.tier,
            z_score: pos.current_z_score,
            hedge_ratio: pos.entry_hedge_ratio,
            entry_price_a: pos.entry_price_a,
            entry_price_b: pos.entry_price_b
          })

        # Update flip tracking on new position
        flipped = %PairPosition{
          new_pos
          | flip_count: pos.flip_count + 1,
            consecutive_losses: new_consecutive,
            last_flip_time: DateTime.utc_now()
        }

        :ets.insert(@table, {flipped.id, flipped})
        persist_async()
        {:ok, flipped}

      [] ->
        :error
    end
  end

  @doc "Check if a position can flip (circuit breaker)."
  def can_flip?(id) do
    case :ets.lookup(@table, id) do
      [{^id, %PairPosition{} = pos}] ->
        max_flips = 4
        max_consecutive_losses = 3

        pos.flip_count < max_flips and
          pos.consecutive_losses < max_consecutive_losses

      [] ->
        false
    end
  end

  defp reverse_direction(:long_a_short_b), do: :long_b_short_a
  defp reverse_direction(:long_b_short_a), do: :long_a_short_b

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
    persist_async()
    :ok
  end

  # GenServer callbacks

  @impl true
  def init(_) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    load_from_disk()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast(:persist, state) do
    do_persist()
    {:noreply, state}
  end

  # ── Persistence ─────────────────────────────────────────────

  defp persist_async do
    # Cast so mutators return fast; write happens in the GenServer process.
    GenServer.cast(__MODULE__, :persist)
  end

  defp file_path do
    Application.get_env(:alpaca_trader, :pair_positions_path, @default_path)
  end

  defp do_persist do
    positions =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, pos} -> pos_to_map(pos) end)

    payload =
      Jason.encode!(%{
        positions: positions,
        count: length(positions),
        updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    final = file_path()
    tmp = final <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(final)),
         :ok <- File.write(tmp, payload),
         :ok <- File.rename(tmp, final) do
      :ok
    else
      {:error, reason} ->
        Logger.error("[PairPositionStore] persist failed: #{inspect(reason)}")
    end
  end

  defp load_from_disk do
    path = file_path()

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"positions" => positions}} when is_list(positions) ->
            restored =
              positions
              |> Enum.map(&map_to_pos/1)
              |> Enum.reject(&is_nil/1)

            Enum.each(restored, fn pos -> :ets.insert(@table, {pos.id, pos}) end)
            open = Enum.count(restored, &(&1.status == :open))

            if restored != [] do
              Logger.info(
                "[PairPositionStore] restored #{length(restored)} positions (#{open} open) from #{path}"
              )
            end

          _ ->
            :ok
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("[PairPositionStore] load failed: #{inspect(reason)}")
    end
  end

  defp pos_to_map(%PairPosition{} = pos) do
    pos
    |> Map.from_struct()
    |> Map.update(:entry_time, nil, &iso_or_nil/1)
    |> Map.update(:last_updated, nil, &iso_or_nil/1)
    |> Map.update(:last_flip_time, nil, &iso_or_nil/1)
    |> Map.update(:direction, nil, &atom_to_string/1)
    |> Map.update(:status, nil, &atom_to_string/1)
  end

  defp map_to_pos(%{"id" => id} = m) do
    %PairPosition{
      id: id,
      asset_a: m["asset_a"],
      asset_b: m["asset_b"],
      direction: parse_direction(m["direction"]),
      tier: m["tier"],
      entry_z_score: m["entry_z_score"],
      entry_hedge_ratio: m["entry_hedge_ratio"],
      entry_price_a: m["entry_price_a"],
      entry_price_b: m["entry_price_b"],
      entry_time: parse_dt(m["entry_time"]),
      half_life: m["half_life"],
      current_z_score: m["current_z_score"],
      bars_held: m["bars_held"] || 0,
      last_updated: parse_dt(m["last_updated"]),
      exit_z_threshold: m["exit_z_threshold"],
      stop_z_threshold: m["stop_z_threshold"],
      max_hold_bars: m["max_hold_bars"],
      status: parse_status(m["status"]),
      flip_count: m["flip_count"] || 0,
      consecutive_losses: m["consecutive_losses"] || 0,
      last_flip_time: parse_dt(m["last_flip_time"])
    }
  end

  defp map_to_pos(_), do: nil

  defp iso_or_nil(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso_or_nil(_), do: nil

  defp atom_to_string(a) when is_atom(a) and not is_nil(a), do: Atom.to_string(a)
  defp atom_to_string(s) when is_binary(s), do: s
  defp atom_to_string(_), do: nil

  defp parse_dt(nil), do: nil

  defp parse_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_dt(%DateTime{} = dt), do: dt
  defp parse_dt(_), do: nil

  defp parse_direction("long_a_short_b"), do: :long_a_short_b
  defp parse_direction("long_b_short_a"), do: :long_b_short_a
  defp parse_direction(a) when is_atom(a), do: a
  defp parse_direction(_), do: nil

  defp parse_status("open"), do: :open
  defp parse_status("closed"), do: :closed
  defp parse_status(a) when is_atom(a), do: a
  defp parse_status(_), do: :closed
end
