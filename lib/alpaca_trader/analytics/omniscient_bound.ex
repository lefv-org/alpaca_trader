defmodule AlpacaTrader.Analytics.OmniscientBound do
  @moduledoc """
  Kearns/Kulesza/Nevmyvaka 2010 — Empirical Limitations on High Frequency
  Trading Profitability (arXiv:1007.2593).

  Computes the *theoretical maximum* P&L an omniscient trader (perfect
  one-step lookahead) could have extracted from a price series, after
  realistic per-trade costs (spread + fees). This establishes an upper
  bound: our live strategy's efficiency = realised_pnl / omniscient_pnl
  is by definition in `[0, 1]`. A strategy at 0.05 of bound is normal;
  one at 0.20+ is exceptional. Anything *above* 1.0 means a bug.

  The original paper used L1 quote ticks; we approximate with bar closes
  (1m, 5m, 1h, 1d depending on what BarsStore holds). Resolution affects
  the absolute number — Kearns showed the bound drops from ~$21B/yr
  (10s holds, US equities 2008) to ~$21M/yr (10ms) — but the *ratio*
  remains a useful efficiency metric.

  ## Algorithm

  Greedy with one-step lookahead:

      pnl = 0
      for i in 0..n-2:
        edge = c[i+1] - c[i]
        cost = max(c[i], c[i+1]) * (spread_bps + fee_bps) / 10_000
        if abs(edge) > cost:
          pnl += abs(edge) - cost

  This assumes one unit traded each bar. Scaling by `notional / mid`
  converts to dollar P&L for a fixed dollar exposure.

  Long-only mode: pnl += max(edge, 0) - cost when edge>cost. The
  bound becomes tighter (typically ~50% of the unconstrained bound
  for symmetric returns).
  """

  @type opts :: [
          spread_bps: number,
          fee_bps: number,
          notional: number,
          long_only: boolean
        ]

  @default_spread_bps 5.0
  @default_fee_bps 1.0
  @default_notional 100.0

  @doc """
  Compute omniscient P&L for a list of close prices.

  Returns `%{pnl: float, trades: integer, gross: float, costs: float,
  hit_rate: float}` where hit_rate is the fraction of bars that were
  profitable to trade (after costs).
  """
  @spec run([number], opts) :: %{
          pnl: float,
          trades: non_neg_integer,
          gross: float,
          costs: float,
          hit_rate: float
        }
  def run(closes, opts \\ []) when is_list(closes) do
    spread_bps = Keyword.get(opts, :spread_bps, @default_spread_bps)
    fee_bps = Keyword.get(opts, :fee_bps, @default_fee_bps)
    notional = Keyword.get(opts, :notional, @default_notional)
    long_only = Keyword.get(opts, :long_only, false)
    cost_bps = spread_bps + fee_bps

    pairs =
      case closes do
        [] -> []
        [_only] -> []
        _ -> Enum.zip(closes, tl(closes))
      end

    n_pairs = length(pairs)

    {pnl, trades, gross, costs} =
      Enum.reduce(pairs, {0.0, 0, 0.0, 0.0}, fn {prev, curr},
                                                {pnl_acc, t_acc, g_acc, c_acc} ->
        units = notional / max(prev, 1.0e-12)
        edge_per_unit = curr - prev
        max_price = max(prev, curr)
        cost_per_unit = max_price * cost_bps / 10_000.0

        edge_dollar = edge_per_unit * units
        cost_dollar = cost_per_unit * units

        cond do
          long_only and edge_per_unit > 0 and edge_dollar > cost_dollar ->
            {pnl_acc + (edge_dollar - cost_dollar), t_acc + 1,
             g_acc + edge_dollar, c_acc + cost_dollar}

          not long_only and abs(edge_dollar) > cost_dollar ->
            {pnl_acc + (abs(edge_dollar) - cost_dollar), t_acc + 1,
             g_acc + abs(edge_dollar), c_acc + cost_dollar}

          true ->
            {pnl_acc, t_acc, g_acc, c_acc}
        end
      end)

    %{
      pnl: pnl,
      trades: trades,
      gross: gross,
      costs: costs,
      hit_rate: if(n_pairs == 0, do: 0.0, else: trades / n_pairs)
    }
  end

  @doc """
  Convenience: compute bound from BarsStore for a single symbol.
  """
  def from_bars_store(symbol, opts \\ []) do
    case AlpacaTrader.BarsStore.get_closes(symbol) do
      {:ok, closes} when length(closes) >= 2 ->
        {:ok, run(closes, opts)}

      _ ->
        {:error, :insufficient_bars}
    end
  end

  @doc """
  Efficiency ratio: realised_pnl / omniscient_pnl, clipped to [-1, ∞).

  Returns:
    * `+1.0` ⇒ matched the omniscient bound (impossible in practice)
    * `0.05–0.20` ⇒ typical good HFT (Kearns 2010 Table 4 baseline)
    * `0.0` ⇒ break-even
    * negative ⇒ realised loss while bound was positive
  """
  @spec efficiency(realised_pnl :: number, bound_pnl :: number) :: float
  def efficiency(realised, bound) when bound > 0, do: realised / bound
  def efficiency(_realised, _bound), do: 0.0
end
