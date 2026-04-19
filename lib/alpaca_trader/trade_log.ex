defmodule AlpacaTrader.TradeLog do
  @moduledoc """
  Append-only log of every closed trade with full context.

  Writes one JSON-lines entry per closed position to `priv/runtime/trades.jsonl`
  (atomically-appended, gitignored). Each entry captures:

  - timestamp, pair, tier, direction
  - entry_z, exit_z, entry_price_a/b, exit_price_a/b
  - hedge_ratio, half_life (if computed), hurst (if computed)
  - bars_held, realized_pnl_pct
  - exit reason (target, stop, time, flip, end_of_day)

  Purpose: post-hoc analysis ("which features actually predicted winners?").
  The live engine keeps no structured history today — trades scroll past in
  the logger and are lost. This gives the operator a queryable record.
  """

  use GenServer
  require Logger

  @default_path "priv/runtime/trades.jsonl"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a closed trade. Fields are loosely shaped — include anything you
  have. Persisted as a single-line JSON object.
  """
  def record(%{} = trade) do
    GenServer.cast(__MODULE__, {:record, trade})
  end

  @doc "Read the log back as a list of parsed entries (newest last)."
  def read_all do
    GenServer.call(__MODULE__, :read_all, 30_000)
  end

  @doc "Current log path."
  def path, do: GenServer.call(__MODULE__, :path)

  @doc """
  Aggregate performance statistics across all recorded trades with a non-nil
  `pnl_pct`. Used by Kelly sizing (and any other module that wants a
  lifetime edge estimate).

  Requires at least 10 completed trades with both wins and losses to return
  a meaningful stats map. Below that threshold returns `%{}` so callers
  can apply a safe fallback (typically the hard max-cap ceiling).

  The shape matches `AlpacaTrader.Backtest.Simulator`'s in-progress
  running stats: `%{win_rate, avg_win_pct, avg_loss_pct}`.
  """
  def performance_stats do
    entries =
      try do
        read_all()
      catch
        :exit, _ -> []
      end

    pnl_pcts =
      entries
      |> Enum.map(&Map.get(&1, "pnl_pct"))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&is_number/1)

    n = length(pnl_pcts)

    if n < 10 do
      %{}
    else
      {wins, losses} = Enum.split_with(pnl_pcts, &(&1 > 0))

      if wins == [] or losses == [] do
        %{}
      else
        %{
          win_rate: length(wins) / n,
          avg_win_pct: Enum.sum(wins) / length(wins),
          avg_loss_pct: abs(Enum.sum(losses) / length(losses))
        }
      end
    end
  end

  # ── GenServer callbacks ────────────────────────────────────

  @impl true
  def init(opts) do
    path = opts[:path] || Application.get_env(:alpaca_trader, :trade_log_path, @default_path)
    File.mkdir_p!(Path.dirname(path))
    {:ok, %{path: path}}
  end

  @impl true
  def handle_cast({:record, trade}, state) do
    payload =
      trade
      |> Map.put_new(:logged_at, DateTime.utc_now() |> DateTime.to_iso8601())
      |> Jason.encode!()

    # Append-only with a newline. File.write with [:append] is atomic for
    # small writes on POSIX; for trade events this is fine.
    File.write(state.path, payload <> "\n", [:append])
    {:noreply, state}
  end

  @impl true
  def handle_call(:read_all, _from, state) do
    entries =
      case File.read(state.path) do
        {:ok, content} ->
          content
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case Jason.decode(line) do
              {:ok, m} -> m
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:error, :enoent} -> []
        {:error, _} -> []
      end

    {:reply, entries, state}
  end

  def handle_call(:path, _from, state), do: {:reply, state.path, state}
end
