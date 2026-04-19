# Cost-Adjusted Calibration Loop

Before trusting a pair whitelist, calibrate backtests against the slippage
the broker is actually delivering. The three modules below compose into a
short loop you can re-run any time fills drift.

## Steps

1. **Measure live slippage.** Run
   `AlpacaTrader.Backtest.SlippageMeasurement.measure/1` against recent
   Alpaca order history. It returns a per-symbol report plus a
   `recommended_slippage_bps` value for backtest calibration.

2. **Walk-forward with the measured cost.** Feed the recommendation into
   the simulator config:

   ```elixir
   WalkForward.run(pairs, bars,
     window_bars: 720,
     step_bars: 240,
     simulator_config: %{slippage_bps: measured_bps}
   )
   ```

   Each per-pair robustness entry now includes
   `sharpe_window_annualized` (mean/std of per-window returns, annualized
   by `sqrt(12)`), computed from the same slippage-adjusted returns.

3. **Gate the whitelist on net Sharpe.** Pass a threshold when generating
   the whitelist so pairs that only win on gross returns are dropped:

   ```elixir
   WhitelistGenerator.generate(wf_result,
     min_win_ratio: 0.66,
     min_net_sharpe: 0.5
   )
   ```

   Start around `0.5` and tighten as the trade count grows. Any pair
   whose cost-adjusted Sharpe falls below the threshold is excluded from
   `priv/runtime/pair_whitelist.json`.
