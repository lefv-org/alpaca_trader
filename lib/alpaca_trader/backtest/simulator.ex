defmodule AlpacaTrader.Backtest.Simulator do
  @moduledoc """
  Pure-function backtest harness for pair-trading strategies.

  Given two aligned price series and a strategy configuration, walks forward
  one bar at a time computing the spread, z-score, and mean-reversion
  statistics over a rolling lookback. Opens and closes positions per the
  entry/exit rules, applying configurable slippage + commission per fill.

  Records every closed trade with full context (entry/exit prices, z-scores,
  realized P&L, holding period) so `Backtest.Report` can compute aggregate
  metrics.

  Not connected to the live engine or the Alpaca client — intentional. This
  is a self-contained simulator. The strategy rules here should mirror the
  engine's entry/exit logic; `Backtest.Report.compare_to_engine/2` is a
  safety check to confirm the behaviors haven't drifted.
  """

  alias AlpacaTrader.Arbitrage.{SpreadCalculator, MeanReversion, HalfLifeManager}

  @type bar :: %{required(:close) => float(), required(:timestamp) => DateTime.t()}
  @type config :: %{
          required(:lookback_bars) => pos_integer(),
          required(:entry_z) => float(),
          required(:exit_z) => float(),
          required(:stop_z) => float(),
          required(:max_hold_bars) => pos_integer(),
          required(:notional) => float(),
          optional(:slippage_bps) => float(),
          optional(:commission_bps) => float(),
          optional(:require_cointegration) => boolean(),
          optional(:max_half_life) => pos_integer(),
          optional(:max_hurst) => float() | nil,
          optional(:position_sizing) => :fixed | :vol_scaled,
          optional(:target_risk_pct) => float()
        }
  @type trade :: %{
          pair: String.t(),
          entry_bar: non_neg_integer(),
          exit_bar: non_neg_integer(),
          entry_z: float(),
          exit_z: float(),
          hold_bars: pos_integer(),
          pnl: float(),
          pnl_pct: float(),
          reason: atom(),
          notional: float()
        }

  @default_config %{
    lookback_bars: 60,
    entry_z: 2.0,
    exit_z: 0.5,
    stop_z: 4.0,
    max_hold_bars: 60,
    notional: 1000.0,
    slippage_bps: 5.0,
    commission_bps: 0.0,
    require_cointegration: true,
    max_half_life: 60,
    max_hurst: 0.75,
    position_sizing: :fixed,
    target_risk_pct: 0.001
  }

  @doc "Default backtest configuration."
  def default_config, do: @default_config

  @doc """
  Run a backtest on a single pair.

  `closes_a` and `closes_b` must be equal-length lists of floats, aligned
  bar-for-bar. Returns a map with `:trades` (list of closed trades),
  `:final_equity`, and `:equity_curve` (per-bar mark-to-market).
  """
  def run_pair(label, closes_a, closes_b, config \\ %{}) do
    config = Map.merge(@default_config, config)
    n = min(length(closes_a), length(closes_b))

    if n < config.lookback_bars + 10 do
      %{trades: [], final_equity: 1.0, equity_curve: [], skipped: :insufficient_bars}
    else
      ca = Enum.take(closes_a, n) |> List.to_tuple()
      cb = Enum.take(closes_b, n) |> List.to_tuple()

      initial_state = %{
        equity: 1.0,
        position: nil,
        trades: [],
        equity_curve: [],
        bar_index: config.lookback_bars
      }

      final_state =
        Enum.reduce(config.lookback_bars..(n - 1), initial_state, fn i, state ->
          step(state, i, ca, cb, config, label)
        end)

      # Force-close any open position at the final bar
      final_state = maybe_force_close(final_state, n - 1, ca, cb, config, label)

      %{
        trades: Enum.reverse(final_state.trades),
        final_equity: final_state.equity,
        equity_curve: Enum.reverse(final_state.equity_curve)
      }
    end
  end

  defp step(state, i, ca, cb, config, label) do
    # Rolling window of closing prices
    window_a = for j <- (i - config.lookback_bars)..i, do: elem(ca, j)
    window_b = for j <- (i - config.lookback_bars)..i, do: elem(cb, j)

    analysis = SpreadCalculator.analyze(window_a, window_b)

    new_state =
      case state.position do
        nil -> maybe_enter(state, i, analysis, window_a, window_b, config, label)
        pos -> maybe_exit(state, pos, i, analysis, ca, cb, config, label)
      end

    # Mark to market — track equity even when flat
    mark_to_market(new_state, i, ca, cb)
  end

  defp maybe_enter(state, _i, nil, _wa, _wb, _cfg, _label), do: state

  defp maybe_enter(state, i, analysis, window_a, window_b, config, _label) do
    z = analysis.z_score
    spread = SpreadCalculator.spread_series(window_a, window_b, analysis.hedge_ratio)

    cond do
      abs(z) < config.entry_z ->
        state

      config.require_cointegration and not cointegrated?(spread, config) ->
        state

      not regime_allows_entry?(spread, window_a, config) ->
        state

      true ->
        # Long the spread means long A, short B (hedge ratio scales B)
        # z > 0 means spread is above mean → expect down → short A, long B
        side_a = if z > 0, do: :sell, else: :buy
        side_b = if z > 0, do: :buy, else: :sell

        price_a_i = Enum.at(window_a, -1)
        price_b_i = Enum.at(window_b, -1)

        {entry_a, entry_b} =
          {
            fill_price(price_a_i, side_a, config),
            fill_price(price_b_i, side_b, config)
          }

        base_notional = compute_notional(state.equity, spread, window_a, window_b, analysis, config)
        notional = kelly_clip(base_notional, state, state.equity * initial_notional(config), config)
        hl = MeanReversion.half_life(spread)

        pos = %{
          side_a: side_a,
          side_b: side_b,
          entry_a: entry_a,
          entry_b: entry_b,
          entry_i: i,
          entry_z: z,
          hedge_ratio: analysis.hedge_ratio,
          notional: notional,
          half_life: hl
        }

        %{state | position: pos, bar_index: i}
    end
  end

  defp maybe_exit(state, pos, i, analysis, ca, cb, config, label) do
    hold_bars = i - pos.entry_i
    z = (analysis && analysis.z_score) || 0.0

    time_stop_mult = Map.get(config, :half_life_time_stop_mult, 2.0)

    effective_time_stop =
      HalfLifeManager.time_stop_bars(pos[:half_life], time_stop_mult,
        fallback_bars: config.max_hold_bars
      )

    exit_reason =
      cond do
        hold_bars >= effective_time_stop -> :max_hold
        abs(z) >= config.stop_z -> :stop
        hold_bars >= 2 and crossed_exit_z?(pos.entry_z, z, config.exit_z) -> :target
        true -> nil
      end

    case exit_reason do
      nil ->
        state

      reason ->
        price_a_i = elem(ca, i)
        price_b_i = elem(cb, i)

        exit_a = fill_price(price_a_i, opposite(pos.side_a), config)
        exit_b = fill_price(price_b_i, opposite(pos.side_b), config)

        # Dollar-neutral pair: both legs get the same notional, so each leg
        # contributes its own percentage return directly. Averaging keeps the
        # total comparable to a single-leg trade's % return.
        pnl_frac = (leg_pnl(pos.entry_a, exit_a, pos.side_a) + leg_pnl(pos.entry_b, exit_b, pos.side_b)) / 2

        commission_cost = 4 * (config.commission_bps / 10_000) * pos.notional
        net_pnl = pnl_frac * pos.notional - commission_cost
        pnl_pct = net_pnl / pos.notional

        trade = %{
          pair: label,
          entry_bar: pos.entry_i,
          exit_bar: i,
          entry_z: pos.entry_z,
          exit_z: z,
          hold_bars: hold_bars,
          pnl: net_pnl,
          pnl_pct: pnl_pct,
          reason: reason,
          notional: pos.notional
        }

        %{
          state
          | position: nil,
            equity: state.equity + net_pnl / initial_notional(config),
            trades: [trade | state.trades]
        }
    end
  end

  defp mark_to_market(state, i, _ca, _cb) do
    equity_curve_entry = {i, state.equity}
    %{state | equity_curve: [equity_curve_entry | state.equity_curve]}
  end

  defp maybe_force_close(state, i, ca, cb, config, label) do
    case state.position do
      nil ->
        state

      pos ->
        window_a = for j <- max(i - config.lookback_bars, 0)..i, do: elem(ca, j)
        window_b = for j <- max(i - config.lookback_bars, 0)..i, do: elem(cb, j)
        analysis = SpreadCalculator.analyze(window_a, window_b)

        price_a_i = elem(ca, i)
        price_b_i = elem(cb, i)

        exit_a = fill_price(price_a_i, opposite(pos.side_a), config)
        exit_b = fill_price(price_b_i, opposite(pos.side_b), config)

        pnl_frac = (leg_pnl(pos.entry_a, exit_a, pos.side_a) + leg_pnl(pos.entry_b, exit_b, pos.side_b)) / 2
        commission_cost = 4 * (config.commission_bps / 10_000) * pos.notional
        net_pnl = pnl_frac * pos.notional - commission_cost
        pnl_pct = net_pnl / pos.notional

        trade = %{
          pair: label,
          entry_bar: pos.entry_i,
          exit_bar: i,
          entry_z: pos.entry_z,
          exit_z: (analysis && analysis.z_score) || 0.0,
          hold_bars: i - pos.entry_i,
          pnl: net_pnl,
          pnl_pct: pnl_pct,
          reason: :end_of_series,
          notional: pos.notional
        }

        %{state | position: nil, equity: state.equity + net_pnl / initial_notional(config), trades: [trade | state.trades]}
    end
  end

  # ── helpers ────────────────────────────────────────────────

  defp fill_price(price, :buy, config), do: price * (1 + config.slippage_bps / 10_000)
  defp fill_price(price, :sell, config), do: price * (1 - config.slippage_bps / 10_000)

  defp opposite(:buy), do: :sell
  defp opposite(:sell), do: :buy

  defp leg_pnl(entry, exit, :buy), do: (exit - entry) / entry
  defp leg_pnl(entry, exit, :sell), do: (entry - exit) / entry

  defp initial_notional(config), do: config.notional

  defp compute_notional(equity, spread, window_a, window_b, analysis, config) do
    base = compute_base_notional(equity, spread, window_a, window_b, analysis, config)

    if Map.get(config, :half_life_size_enabled, false) do
      hl = MeanReversion.half_life(spread)
      mult = HalfLifeManager.size_multiplier(hl)
      base * mult
    else
      base
    end
  end

  # Kelly-fractional *ceiling* on notional. Never increases size; only clips
  # down if the Kelly cap is tighter than the vol-scaled amount. Stats are
  # derived from the in-progress trade history — at least 10 trades required
  # before a real Kelly cap kicks in; below that we fall back to the
  # max_cap_pct policy floor (via `KellySizer.size_cap`).
  defp kelly_clip(notional, state, equity_dollars, config) do
    if Map.get(config, :kelly_enabled, false) and equity_dollars > 0 do
      stats = running_stats(state.trades)

      cap =
        AlpacaTrader.Arbitrage.KellySizer.size_cap(equity_dollars, stats,
          fraction: Map.get(config, :kelly_fraction, 0.5),
          max_cap_pct: Map.get(config, :kelly_max_cap_pct, 0.10)
        )

      # Never clip below a minimum viable notional; if the Kelly cap is <= 0
      # (equity collapse, etc.), fall back to the incoming notional rather
      # than creating a divide-by-zero downstream.
      if cap > 0, do: min(notional, cap), else: notional
    else
      notional
    end
  end

  defp running_stats([]), do: %{}

  defp running_stats(trades) do
    n = length(trades)

    if n < 10 do
      %{}
    else
      wins = Enum.filter(trades, &(&1.pnl_pct > 0))
      losses = Enum.filter(trades, &(&1.pnl_pct <= 0))
      win_n = length(wins)
      loss_n = length(losses)

      cond do
        win_n == 0 or loss_n == 0 ->
          %{}

        true ->
          %{
            win_rate: win_n / n,
            avg_win_pct: avg(Enum.map(wins, & &1.pnl_pct)),
            avg_loss_pct: abs(avg(Enum.map(losses, & &1.pnl_pct)))
          }
      end
    end
  end

  defp avg([]), do: 0.0
  defp avg(xs), do: Enum.sum(xs) / length(xs)

  defp compute_base_notional(_equity, _spread, _wa, _wb, _analysis, %{position_sizing: :fixed} = config) do
    config.notional
  end

  defp compute_base_notional(equity, spread, _window_a, _window_b, _analysis, config) do
    # Vol-scaled: target_risk / (spread_std * stop_z)
    n = length(spread)
    mean = Enum.sum(spread) / n
    variance = Enum.reduce(spread, 0.0, fn x, acc -> acc + :math.pow(x - mean, 2) end) / max(n - 1, 1)
    std = :math.sqrt(variance)

    if std > 0 do
      target_risk_dollars = equity * initial_notional(config) * config.target_risk_pct * 100_000
      per_bar_risk = std * config.stop_z
      # Convert to a multiple of fixed notional (approximately)
      raw = target_risk_dollars / max(per_bar_risk, 1.0e-6)
      # Bound between 0.25x and 4x fixed notional
      min(max(raw, 0.25 * config.notional), 4.0 * config.notional)
    else
      config.notional
    end
  end

  defp cointegrated?(spread, config) do
    case MeanReversion.classify(spread,
           max_half_life: config.max_half_life,
           max_hurst: config.max_hurst
         ) do
      {:ok, _} -> true
      {:reject, _} -> false
    end
  end

  defp regime_allows_entry?(spread, window_a, config) do
    regime_opts = [
      enabled: Map.get(config, :regime_filter_enabled, false),
      max_realized_vol: Map.get(config, :regime_max_realized_vol, 1.0),
      max_adf_pvalue: Map.get(config, :regime_max_adf_pvalue)
    ]

    case AlpacaTrader.RegimeDetector.allow_entry?(
           %{spread: spread, symbol_a_closes: window_a, bar_frequency: :hourly},
           regime_opts
         ) do
      :ok -> true
      {:blocked, _} -> false
    end
  end

  defp crossed_exit_z?(entry_z, current_z, exit_threshold) do
    # If entered long spread (entry_z negative) → exit when z returns above -exit_threshold
    # If entered short spread (entry_z positive) → exit when z returns below +exit_threshold
    cond do
      entry_z < 0 and current_z > -exit_threshold -> true
      entry_z > 0 and current_z < exit_threshold -> true
      true -> false
    end
  end
end
