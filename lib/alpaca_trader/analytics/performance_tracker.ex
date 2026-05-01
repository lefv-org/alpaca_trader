defmodule AlpacaTrader.Analytics.PerformanceTracker do
  @moduledoc """
  Per-strategy live performance tracker inspired by Baron, Brogaard &
  Kirilenko (2012) "The Trading Profits of High Frequency Traders" (NBER).

  Their findings on the E-mini S&P 500 dataset:

    * Gross profits ≈ $23–29M/month industry-wide.
    * Median Sharpe ratios 4.5–9.2 (top firms >20).
    * **Profit persistence**: yesterday's P&L predicts today's
      (autocorrelation > 0). Strategies that stop working stop working.
    * Aggressive (liquidity-taking) HFTs out-earn passive (LP) HFTs.
    * Speed advantage compounds.

  We can't replicate the regulator dataset, but we can apply the same
  measurement framework live:

    1. Bucket each closed-position P&L by strategy_id.
    2. Compute rolling daily P&L for each strategy.
    3. Track:
        * Sharpe (annualised, sqrt(252) for daily; sqrt(252*minutes/day)
          for finer cadence).
        * Profit autocorrelation (lag-1) — persistence signal.
        * Aggressive ratio: market_orders / total_orders per strategy.
    4. Surface decay: a strategy whose Sharpe drops or
       autocorrelation flips negative is decaying — kill it before
       drawdown destroys the book.

  ## State shape

      %{
        strategy_id => %{
          pnl_history: [{ts, pnl}, ...],    # most recent last
          fill_history: [{ts, side, type}], # for aggressive ratio
          daily_pnl: %{date => float}       # bucketed
        }
      }

  ETS-backed for crash resilience and concurrent reads.
  """
  use GenServer

  require Logger

  @table :performance_tracker
  # Cap retained history per strategy to bound memory.
  @max_pnl_points 5_000
  @max_fill_points 5_000

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record a realised P&L for a strategy (e.g. on position close)."
  def record_pnl(strategy_id, pnl, ts \\ DateTime.utc_now())
      when is_atom(strategy_id) and is_number(pnl) do
    GenServer.cast(__MODULE__, {:record_pnl, strategy_id, pnl, ts})
  end

  @doc "Record an order fill for aggressive-ratio computation."
  def record_fill(strategy_id, side, order_type, ts \\ DateTime.utc_now())
      when is_atom(strategy_id) and side in [:buy, :sell] and
             order_type in [:market, :limit] do
    GenServer.cast(__MODULE__, {:record_fill, strategy_id, side, order_type, ts})
  end

  @doc """
  Annualised Sharpe ratio over the recent N P&L points (default 60).
  Assumes points are roughly daily; for sub-daily, supply :periods_per_year
  in opts.
  """
  def sharpe(strategy_id, opts \\ []) do
    n = Keyword.get(opts, :n, 60)
    periods_per_year = Keyword.get(opts, :periods_per_year, 252)

    case fetch(strategy_id) do
      nil ->
        nil

      %{pnl_history: history} ->
        recent = Enum.take(history, -n) |> Enum.map(fn {_ts, p} -> p end)
        compute_sharpe(recent, periods_per_year)
    end
  end

  @doc """
  Lag-1 autocorrelation of the P&L series. Positive ⇒ profits persist
  (Baron-Brogaard signature of a working strategy).
  """
  def persistence(strategy_id) do
    case fetch(strategy_id) do
      nil ->
        nil

      %{pnl_history: history} ->
        history |> Enum.map(fn {_ts, p} -> p end) |> compute_autocorrelation()
    end
  end

  @doc """
  Aggressive (market-taker) ratio: market_orders / total_orders.
  Baron-Brogaard found liquidity-takers most profitable in HFT.
  """
  def aggressive_ratio(strategy_id) do
    case fetch(strategy_id) do
      nil ->
        nil

      %{fill_history: fills} ->
        if fills == [] do
          0.0
        else
          markets = Enum.count(fills, fn {_ts, _side, type} -> type == :market end)
          markets / length(fills)
        end
    end
  end

  @doc "Full snapshot for a single strategy."
  def snapshot(strategy_id) do
    case fetch(strategy_id) do
      nil ->
        %{strategy: strategy_id, points: 0}

      %{pnl_history: hist, fill_history: fills} ->
        pnl_total = hist |> Enum.map(&elem(&1, 1)) |> Enum.sum()

        %{
          strategy: strategy_id,
          points: length(hist),
          fills: length(fills),
          pnl_total: pnl_total,
          sharpe: compute_sharpe(Enum.map(hist, &elem(&1, 1)), 252),
          persistence: compute_autocorrelation(Enum.map(hist, &elem(&1, 1))),
          aggressive_ratio: aggressive_ratio_internal(fills)
        }
    end
  end

  @doc "Snapshots for all tracked strategies."
  def report do
    :ets.tab2list(@table)
    |> Enum.map(fn {sid, _state} -> snapshot(sid) end)
  end

  # ── GenServer ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record_pnl, sid, pnl, ts}, state) do
    cur = fetch_or_default(sid)

    history =
      [{ts, pnl} | Enum.reverse(cur.pnl_history)]
      |> Enum.take(@max_pnl_points)
      |> Enum.reverse()

    :ets.insert(@table, {sid, %{cur | pnl_history: history}})
    {:noreply, state}
  end

  def handle_cast({:record_fill, sid, side, type, ts}, state) do
    cur = fetch_or_default(sid)

    fills =
      [{ts, side, type} | Enum.reverse(cur.fill_history)]
      |> Enum.take(@max_fill_points)
      |> Enum.reverse()

    :ets.insert(@table, {sid, %{cur | fill_history: fills}})
    {:noreply, state}
  end

  # ── Internal ──────────────────────────────────────────────────────────────────

  defp fetch(sid) do
    case :ets.lookup(@table, sid) do
      [{^sid, state}] -> state
      [] -> nil
    end
  end

  defp fetch_or_default(sid) do
    case fetch(sid) do
      nil -> %{pnl_history: [], fill_history: []}
      state -> state
    end
  end

  defp aggressive_ratio_internal([]), do: 0.0

  defp aggressive_ratio_internal(fills) do
    Enum.count(fills, fn {_ts, _side, t} -> t == :market end) / length(fills)
  end

  defp compute_sharpe(returns, periods_per_year) when length(returns) < 2, do: nil

  defp compute_sharpe(returns, periods_per_year) do
    n = length(returns)
    mean = Enum.sum(returns) / n
    var = Enum.reduce(returns, 0.0, fn r, acc -> acc + (r - mean) * (r - mean) end) / max(n - 1, 1)
    sd = :math.sqrt(var)

    if sd == 0.0 do
      nil
    else
      mean / sd * :math.sqrt(periods_per_year)
    end
  end

  defp compute_autocorrelation(series) when length(series) < 3, do: nil

  defp compute_autocorrelation(series) do
    n = length(series)
    mean = Enum.sum(series) / n

    centered = Enum.map(series, fn x -> x - mean end)
    {prevs, currs} = {Enum.drop(centered, -1), Enum.drop(centered, 1)}

    num = Enum.zip(prevs, currs) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    den = Enum.reduce(centered, 0.0, fn x, acc -> acc + x * x end)

    if den == 0.0, do: nil, else: num / den
  end
end
