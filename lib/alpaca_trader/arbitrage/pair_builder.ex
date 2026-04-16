defmodule AlpacaTrader.Arbitrage.PairBuilder do
  @moduledoc """
  Dynamically discovers correlated asset pairs by computing a correlation
  matrix from recent price data. Runs periodically to update the relationship
  graph without manual configuration.

  Uses 1-minute bars for fast-moving crypto and 1-day bars for equities.
  Pairs that pass correlation + cointegration filters become active trading pairs.
  """

  use GenServer

  alias AlpacaTrader.Alpaca.Client
  alias AlpacaTrader.Arbitrage.{SpreadCalculator, MeanReversion}

  require Logger

  @correlation_threshold 0.65
  @min_bars 20
  @max_pairs 100

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Get all dynamically discovered pairs."
  def dynamic_pairs do
    GenServer.call(__MODULE__, :get_pairs, 60_000)
  end

  @doc "Trigger a rebuild of the dynamic pair graph."
  def rebuild do
    GenServer.call(__MODULE__, :rebuild, 120_000)
  end

  @doc "Number of dynamic pairs currently active."
  def pair_count do
    GenServer.call(__MODULE__, :count)
  end

  # GenServer callbacks

  @impl true
  def init(_) do
    {:ok, %{pairs: [], last_built: nil}}
  end

  @impl true
  def handle_call(:get_pairs, _from, state) do
    {:reply, state.pairs, state}
  end

  @impl true
  def handle_call(:count, _from, state) do
    {:reply, length(state.pairs), state}
  end

  @impl true
  def handle_call(:rebuild, _from, _state) do
    Logger.info("[PairBuilder] rebuilding dynamic pair graph")

    pairs = build_pairs()

    Logger.info("[PairBuilder] discovered #{length(pairs)} correlated pairs")

    {:reply, {:ok, length(pairs)},
     %{pairs: pairs, last_built: DateTime.utc_now()}}
  end

  # ── PAIR BUILDING LOGIC ────────────────────────────────────

  defp build_pairs do
    # Get all crypto symbols from AssetStore
    crypto_symbols =
      AlpacaTrader.AssetStore.all()
      |> Enum.filter(fn a -> a["class"] == "crypto" and a["tradable"] == true end)
      |> Enum.map(& &1["symbol"])

    if length(crypto_symbols) < 2 do
      []
    else
      # Fetch 1-minute bars for all crypto (last 60 minutes)
      bars_map = fetch_minute_bars(crypto_symbols)

      # Build return series for each symbol
      returns_map =
        bars_map
        |> Enum.map(fn {symbol, bars} ->
          closes = bars |> Enum.sort_by(& &1["t"]) |> Enum.map(& &1["c"])

          if length(closes) >= @min_bars do
            returns = compute_returns(closes)
            {symbol, returns}
          else
            nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Map.new()

      symbols_with_data = Map.keys(returns_map)

      # Compute correlations for all pairs
      find_correlated_pairs(symbols_with_data, returns_map)
    end
  end

  defp fetch_minute_bars(symbols) do
    # Fetch each symbol individually — Alpaca's limit is total bars across all symbols
    symbols
    |> Enum.reduce(%{}, fn sym, acc ->
      case Client.get_crypto_bars([sym], %{timeframe: "1Min", limit: 60}) do
        {:ok, %{"bars" => %{^sym => bars}}} when is_list(bars) ->
          Map.put(acc, sym, bars)

        _ ->
          acc
      end
    end)
  end

  defp compute_returns(closes) when length(closes) < 2, do: []

  defp compute_returns(closes) do
    closes
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [prev, curr] ->
      if prev > 0, do: (curr - prev) / prev, else: 0.0
    end)
  end

  defp find_correlated_pairs(symbols, returns_map) do
    # Generate all unique pairs
    pairs =
      for i <- 0..(length(symbols) - 2),
          j <- (i + 1)..(length(symbols) - 1) do
        a = Enum.at(symbols, i)
        b = Enum.at(symbols, j)
        returns_a = returns_map[a]
        returns_b = returns_map[b]

        # Align to same length
        len = min(length(returns_a), length(returns_b))

        if len >= @min_bars - 1 do
          ra = Enum.take(returns_a, -len)
          rb = Enum.take(returns_b, -len)
          corr = correlation(ra, rb)

          if abs(corr) >= @correlation_threshold do
            # Compute z-score from price levels
            closes_a =
              AlpacaTrader.BarsStore.get_closes(a)
              |> case do
                {:ok, c} -> c
                _ -> []
              end

            closes_b =
              AlpacaTrader.BarsStore.get_closes(b)
              |> case do
                {:ok, c} -> c
                _ -> []
              end

            build_pair_with_cointegration(a, b, corr, closes_a, closes_b)
          end
        end
      end
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn p -> -abs(p.correlation) end)
      |> Enum.take(@max_pairs)

    pairs
  end

  # Apply the MeanReversion.classify gate to ensure the spread is actually
  # stationary with a reasonable half-life. Correlation alone is insufficient —
  # two trending assets can correlate at 0.9 and never mean-revert.
  defp build_pair_with_cointegration(a, b, corr, closes_a, closes_b) do
    if length(closes_a) >= @min_bars and length(closes_b) >= @min_bars do
      l = min(length(closes_a), length(closes_b))
      ca = Enum.take(closes_a, -l)
      cb = Enum.take(closes_b, -l)

      analysis = SpreadCalculator.analyze(ca, cb)

      if analysis do
        spread = SpreadCalculator.spread_series(ca, cb, analysis.hedge_ratio)

        if cointegration_gate_enabled?() do
          case MeanReversion.classify(spread,
                 max_half_life: max_half_life_bars(),
                 max_hurst: max_hurst()
               ) do
            {:ok, mr} ->
              %{
                asset_a: a,
                asset_b: b,
                correlation: Float.round(corr, 4),
                z_score: analysis.z_score,
                hedge_ratio: analysis.hedge_ratio,
                half_life: mr.half_life,
                hurst: mr.hurst,
                adf_t_stat: mr.adf.t_stat,
                source: :dynamic
              }

            {:reject, reason} ->
              Logger.debug("[PairBuilder] rejected #{a}-#{b} (corr=#{Float.round(corr, 2)}): #{inspect(reason)}")
              nil
          end
        else
          %{
            asset_a: a,
            asset_b: b,
            correlation: Float.round(corr, 4),
            z_score: analysis.z_score,
            hedge_ratio: analysis.hedge_ratio,
            source: :dynamic
          }
        end
      end
    end
  end

  defp cointegration_gate_enabled? do
    Application.get_env(:alpaca_trader, :pair_cointegration_gate, true)
  end

  defp max_half_life_bars do
    Application.get_env(:alpaca_trader, :pair_max_half_life_bars, 60)
  end

  defp max_hurst do
    Application.get_env(:alpaca_trader, :pair_max_hurst, 0.75)
  end

  defp correlation(xs, ys) when length(xs) < 2 or length(ys) < 2, do: 0.0

  defp correlation(xs, ys) do
    n = length(xs)
    mean_x = Enum.sum(xs) / n
    mean_y = Enum.sum(ys) / n

    cov =
      Enum.zip(xs, ys)
      |> Enum.map(fn {x, y} -> (x - mean_x) * (y - mean_y) end)
      |> Enum.sum()
      |> Kernel./(n)

    std_x = :math.sqrt(Enum.map(xs, fn x -> (x - mean_x) ** 2 end) |> Enum.sum() |> Kernel./(n))
    std_y = :math.sqrt(Enum.map(ys, fn y -> (y - mean_y) ** 2 end) |> Enum.sum() |> Kernel./(n))

    if std_x > 0 and std_y > 0 do
      cov / (std_x * std_y)
    else
      0.0
    end
  end
end
