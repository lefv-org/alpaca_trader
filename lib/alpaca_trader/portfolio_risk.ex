defmodule AlpacaTrader.PortfolioRisk do
  @moduledoc """
  Portfolio-level entry gates. Complements the per-trade gates (PDT, buying
  power, gain accumulator) by preventing the engine from accumulating
  dangerous concentrations even when each individual trade looks fine.

  Gates (all configurable, all optional):
  - `max_open_positions` — absolute cap on concurrent open pairs
  - `max_per_sector` — cap on open pairs per sector (crypto/equity/etc.)
  - `max_capital_at_risk_pct` — cap the total $ at risk across all positions

  A refused entry returns `{:blocked, reason}` the engine can surface. Pure
  query functions; no state of its own (reads from `PairPositionStore`).
  """

  alias AlpacaTrader.PairPositionStore

  @doc """
  Check whether a new entry for `arb` is allowed under current portfolio
  limits. Returns `:ok` or `{:blocked, reason}`.
  """
  def allow_entry?(arb) when is_map(arb) do
    open = PairPositionStore.open_positions()

    with :ok <- check_max_open(open),
         :ok <- check_per_sector(open, arb),
         :ok <- check_cluster(open, arb) do
      :ok
    end
  end

  @doc """
  Signal-shaped portfolio gate. Builds a synthetic arb-like map per leg
  and reuses existing `allow_entry?/1`. Returns `:ok` or `{:blocked, reason}`.
  """
  def allow_entry_for_signal(%AlpacaTrader.Types.Signal{legs: legs}) do
    Enum.reduce_while(legs, :ok, fn leg, _ ->
      # TODO: full sector/cluster analysis requires a real pair; this synthetic
      # map satisfies the existing `allow_entry?/1` shape for an MVP gate.
      fake_arb = %{asset: leg.symbol, pair_asset: leg.symbol, direction: :long_a_short_b}
      case allow_entry?(fake_arb) do
        :ok -> {:cont, :ok}
        {:blocked, reason} -> {:halt, {:blocked, reason}}
      end
    end)
  end

  @doc "All currently-enforced limits as a map (for logging / ops)."
  def current_limits do
    %{
      max_open_positions: max_open_positions(),
      max_per_sector: max_per_sector(),
      max_capital_at_risk_pct: max_capital_at_risk_pct()
    }
  end

  # ── Gates ──────────────────────────────────────────────────

  defp check_max_open(open) do
    limit = max_open_positions()

    if limit && length(open) >= limit do
      {:blocked, "max open positions reached (#{length(open)}/#{limit})"}
    else
      :ok
    end
  end

  defp check_per_sector(open, arb) do
    limit = max_per_sector()

    if limit do
      sector = sector_for(arb.asset)
      in_sector = Enum.count(open, fn p -> sector_for(p.asset_a) == sector end)

      if in_sector >= limit do
        {:blocked, "sector #{sector} at limit (#{in_sector}/#{limit})"}
      else
        :ok
      end
    else
      :ok
    end
  end

  # Delegate correlation-cluster check to ClusterLimiter when enabled.
  # Engine arbs carry `:asset`/`:pair_asset`; open positions use
  # `:asset_a`/`:asset_b`. Normalize the arb before handing off.
  defp check_cluster(open, arb) do
    if Application.get_env(:alpaca_trader, :cluster_limiter_enabled, false) do
      arb_pair = %{
        asset_a: Map.get(arb, :asset) || Map.get(arb, :asset_a),
        asset_b: Map.get(arb, :pair_asset) || Map.get(arb, :asset_b)
      }

      all_symbols =
        [arb_pair.asset_a, arb_pair.asset_b] ++
          Enum.flat_map(open, fn p -> [Map.get(p, :asset_a), Map.get(p, :asset_b)] end)

      series = fetch_return_series_for(all_symbols)

      if map_size(series) < 2 do
        :ok
      else
        opts = [
          series: series,
          correlation_threshold:
            Application.get_env(:alpaca_trader, :cluster_corr_threshold, 0.8),
          max_per_cluster: Application.get_env(:alpaca_trader, :max_pairs_per_cluster, 3)
        ]

        case AlpacaTrader.Arbitrage.ClusterLimiter.allow_entry?(arb_pair, open, opts) do
          :ok ->
            :ok

          {:blocked, {:cluster_full, members}} ->
            {:blocked, "cluster exposure cap reached (members: #{Enum.join(members, ", ")})"}
        end
      end
    else
      :ok
    end
  end

  defp fetch_return_series_for(symbols) do
    symbols
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(fn s -> {s, AlpacaTrader.BarsStore.recent_returns(s, 200)} end)
    |> Enum.reject(fn {_, series} -> series == [] or length(series) < 2 end)
    |> Map.new()
  end

  # Symbols with "/" are crypto pairs in Alpaca; everything else equities.
  # Extend with a real taxonomy if/when you introduce sector labels.
  defp sector_for(symbol) when is_binary(symbol) do
    if String.contains?(symbol, "/"), do: :crypto, else: :equity
  end

  defp sector_for(_), do: :unknown

  # ── Config readers ─────────────────────────────────────────

  defp max_open_positions,
    do: Application.get_env(:alpaca_trader, :portfolio_max_open_positions, 10)

  defp max_per_sector,
    do: Application.get_env(:alpaca_trader, :portfolio_max_per_sector, 8)

  defp max_capital_at_risk_pct,
    do: Application.get_env(:alpaca_trader, :portfolio_max_capital_at_risk_pct, 0.5)
end
