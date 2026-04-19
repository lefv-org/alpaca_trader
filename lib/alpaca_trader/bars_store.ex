defmodule AlpacaTrader.BarsStore do
  @moduledoc """
  In-memory store for historical price bars, backed by ETS.
  Populated by the BarsSyncJob on a recurring schedule.

  Key: symbol string
  Value: list of bar maps (as returned by Alpaca)
  """

  use GenServer

  @table :bars_store

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Store bars for multiple symbols at once.
  Expects a map of `%{"AAPL" => [bar1, bar2, ...], "MSFT" => [...]}`.
  Merges into existing data (overwrites per-symbol).
  """
  def put_all_bars(bars_map) when is_map(bars_map) do
    GenServer.call(__MODULE__, {:put_all, bars_map})
  end

  @doc "Look up bars for a single symbol."
  def get(symbol) do
    case :ets.lookup(@table, symbol) do
      [{^symbol, bars}] -> {:ok, bars}
      [] -> :error
    end
  end

  @doc """
  Extract close prices for a symbol, sorted by timestamp ascending.
  Returns `{:ok, [float]}` or `:error`.
  """
  def get_closes(symbol) do
    case get(symbol) do
      {:ok, bars} ->
        closes =
          bars
          |> Enum.sort_by(fn bar -> bar["t"] end)
          |> Enum.map(fn bar -> bar["c"] end)

        {:ok, closes}

      :error ->
        :error
    end
  end

  @doc """
  Get closes for a symbol, preferring 1-minute bars (fresher) then falling back to daily bars.
  Minute bars must have at least 20 points to be usable by SpreadCalculator.
  """
  def get_closes_best(symbol) do
    case AlpacaTrader.MinuteBarCache.get_closes(symbol) do
      {:ok, closes} when length(closes) >= 20 -> {:ok, closes}
      _ -> get_closes(symbol)
    end
  end

  @doc """
  Return the last `n` arithmetic returns for a symbol's close series.

  Pulls bars via `get_closes/1` (timestamp-ascending), computes
  `(p_t - p_{t-1}) / p_{t-1}` and returns the tail of length `n`.

  Returns `[]` when the symbol is unknown or has fewer than 2 closes.
  """
  def recent_returns(symbol, n) when is_integer(n) and n > 0 do
    case get_closes(symbol) do
      {:ok, closes} when is_list(closes) and length(closes) >= 2 ->
        closes
        |> compute_returns()
        |> Enum.take(-n)

      _ ->
        []
    end
  end

  defp compute_returns(prices) do
    prices
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [a, b] when is_number(a) and is_number(b) and a != 0 -> [(b - a) / a]
      _ -> []
    end)
  end

  @doc "Count of symbols stored."
  def count do
    case :ets.info(@table) do
      :undefined ->
        0

      _ ->
        :ets.tab2list(@table)
        |> Enum.reject(fn {k, _} -> is_atom(k) end)
        |> length()
    end
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
  def handle_call({:put_all, bars_map}, _from, state) do
    :ets.delete_all_objects(@table)

    Enum.each(bars_map, fn {symbol, bars} ->
      :ets.insert(@table, {symbol, bars})
    end)

    :ets.insert(@table, {:__meta_last_synced_at__, DateTime.utc_now()})

    {:reply, :ok, state}
  end
end
