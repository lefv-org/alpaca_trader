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
         :ok <- check_per_sector(open, arb) do
      :ok
    end
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
