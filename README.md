# AlpacaTrader

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix

## Feature Flags

The trading-bot improvements are shipped behind env-var flags. All default **off**, so behavior is unchanged until explicitly enabled. Set these in your `.env` or deployment environment.

### Regime filter

| Env var | Default | Description |
| --- | --- | --- |
| `REGIME_FILTER_ENABLED` | `false` | Block entries on vol spikes or spread ADF drift. |
| `REGIME_MAX_REALIZED_VOL` | `1.0` | Annualized realized-vol ceiling. |
| `REGIME_MAX_ADF_PVALUE` | `nil` | ADF p-value ceiling for live spread stationarity check. |

### Half-life management

| Env var | Default | Description |
| --- | --- | --- |
| `HALF_LIFE_TIME_STOP_MULT` | `2.0` | Force-close positions at `k × half_life` bars. |
| `HALF_LIFE_SIZE_ENABLED` | `false` | Scale notional inversely with half-life. |

### Kelly fractional sizing

| Env var | Default | Description |
| --- | --- | --- |
| `KELLY_ENABLED` | `false` | Apply Kelly-fractional cap to order notional. |
| `KELLY_FRACTION` | `0.5` | Fractional Kelly multiplier. |
| `KELLY_MAX_CAP_PCT` | `0.05` | Hard ceiling on per-trade equity fraction. |

### Order execution

| Env var | Default | Description |
| --- | --- | --- |
| `ORDER_TYPE_MODE` | `market` | `market` or `marketable_limit`. |
| `MARKETABLE_LIMIT_SPREAD_MULT` | `0.25` | `k` for `ask + k*(ask-bid)` IOC limit price. |

### Correlation cluster limiter

| Env var | Default | Description |
| --- | --- | --- |
| `CLUSTER_LIMITER_ENABLED` | `false` | Cap concurrent positions per correlation cluster. |
| `CLUSTER_CORR_THRESHOLD` | `0.8` | Pearson threshold for cluster membership. |
| `MAX_PAIRS_PER_CLUSTER` | `3` | Max concurrent positions in one cluster. |

### Weekly re-cointegration

| Env var | Default | Description |
| --- | --- | --- |
| `RECOINTEGRATION_LOOKBACK_BARS` | `500` | Window for weekly ADF re-test. |

### Shadow-mode signal logger

| Env var | Default | Description |
| --- | --- | --- |
| `SHADOW_MODE_ENABLED` | `false` | Log every engine entry/exit signal to JSONL. |
| `SHADOW_LOG_PATH` | `priv/runtime/shadow_signals.jsonl` | Shadow log destination. |
