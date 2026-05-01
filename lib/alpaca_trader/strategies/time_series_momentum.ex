defmodule AlpacaTrader.Strategies.TimeSeriesMomentum do
  @moduledoc """
  Time-Series Momentum (TSM) — Moskowitz, Ooi & Pedersen, JFE 104(2), 2012.

  ## Core rule

      excess_12m = close[-1] / close[-12m] - 1
      sign       = excess_12m > 0

      target_long  = sign and (sign == :positive)
      target_short = sign and (sign == :negative)

  Position is sized to a constant volatility target (default 40% annualised
  vol per leg, matching Moskowitz et al's normalisation):

      sigma_ann   = std(daily_returns) * sqrt(252)
      size_factor = vol_target / sigma_ann      # ratio
      qty_dollars = base_notional * size_factor

  Cap the size factor at 5x to prevent runaway leverage when realised vol
  is microscopic. Long-only mode suppresses the SHORT leg by default.

  ## Why on minute-cadence

  TSM is a *position* signal, not a microstructure signal. We re-evaluate
  every scan tick (1 min) but the underlying signal moves on a daily/
  weekly timescale. Re-entering on the same +12mo signal is fine because
  the held-on-Alpaca pre-flight gate (PR #35-#37) blocks duplicates.

  ## References
  Moskowitz/Ooi/Pedersen 2012 — original.
  Hurst/Ooi/Pedersen 2017 — replication on longer sample.
  Georgopoulou/Wang 2017 — broader asset classes.
  """

  @behaviour AlpacaTrader.Strategy

  require Logger

  alias AlpacaTrader.Types.{Signal, Leg, FeedSpec}
  alias AlpacaTrader.BarsStore

  @conviction 0.7

  # 252 trading days ~ 12 months. Use 12 months exact when available;
  # fall back gracefully on shorter histories down to @min_bars.
  @lookback_bars 252
  @min_bars 60

  # Target annualised vol per leg (40% matches Moskowitz et al normalisation).
  @vol_target 0.40

  # Caps to prevent runaway leverage.
  @max_size_factor 5.0
  @min_size_factor 0.1

  # Defaults if AS_SYMBOLS env unset.
  @default_symbols ~w[SPY QQQ DIA IWM GLD TLT]

  @impl true
  def id, do: :time_series_momentum

  @impl true
  def required_feeds do
    [%FeedSpec{venue: :alpaca, symbols: :whitelist, cadence: :minute}]
  end

  @impl true
  def init(config) do
    state = %{
      symbols: resolve_list(config, :symbols, "TSM_SYMBOLS", @default_symbols),
      vol_target: resolve_float(config, :vol_target, "TSM_VOL_TARGET", @vol_target),
      base_notional: resolve_float(config, :base_notional, "TSM_NOTIONAL", 5.0),
      lookback_bars: resolve_int(config, :lookback_bars, "TSM_LOOKBACK", @lookback_bars),
      min_bars: resolve_int(config, :min_bars, "TSM_MIN_BARS", @min_bars),
      open_positions: %{}
    }

    Logger.info(
      "[TSM] init symbols=#{inspect(state.symbols)} vol_target=#{state.vol_target} " <>
        "lookback=#{state.lookback_bars} notional=#{state.base_notional}"
    )

    {:ok, state}
  end

  @impl true
  def scan(state, _ctx) do
    long_only = Application.get_env(:alpaca_trader, :long_only_mode, true)

    signals =
      Enum.reduce(state.symbols, [], fn symbol, acc ->
        case build_signal(symbol, state, long_only) do
          nil -> acc
          sig -> [sig | acc]
        end
      end)

    {:ok, signals, state}
  end

  @impl true
  def exits(state, _ctx), do: {:ok, [], state}

  @impl true
  def on_fill(state, fill) do
    {:ok,
     %{
       state
       | open_positions: Map.update(state.open_positions, fill.symbol, 1, &(&1 + 1))
     }}
  end

  # ── Core ────────────────────────────────────────────────────────────────────

  defp build_signal(symbol, state, long_only) do
    with {:ok, closes} <- BarsStore.get_closes(symbol),
         true <- length(closes) >= state.min_bars,
         {ret_12m, sigma_ann} <- compute_return_and_vol(closes, state.lookback_bars),
         true <- is_number(ret_12m) and is_number(sigma_ann) and sigma_ann > 0 do
      side =
        cond do
          ret_12m > 0 -> :buy
          ret_12m < 0 and not long_only -> :sell
          true -> nil
        end

      if side do
        size_factor =
          (state.vol_target / sigma_ann)
          |> min(@max_size_factor)
          |> max(@min_size_factor)

        notional = state.base_notional * size_factor

        Signal.new(
          strategy: id(),
          conviction: @conviction,
          reason:
            "TSM #{side} #{symbol}: ret_12m=#{Float.round(ret_12m, 4)} " <>
              "σ_ann=#{Float.round(sigma_ann, 4)} sf=#{Float.round(size_factor, 3)}",
          ttl_ms: 300_000,
          legs: [
            %Leg{
              venue: :alpaca,
              symbol: symbol,
              side: side,
              size: Decimal.from_float(notional),
              size_mode: :notional,
              type: :market,
              limit_price: nil
            }
          ]
        )
      end
    else
      _ -> nil
    end
  end

  defp compute_return_and_vol(closes, lookback) do
    n = length(closes)
    take = min(n, lookback + 1)
    window = Enum.take(closes, -take)

    case window do
      [first | _] = list when length(list) >= 2 ->
        last = List.last(list)

        ret_12m =
          if first > 0, do: last / first - 1.0, else: 0.0

        sigma_ann = annualised_vol(list)
        {ret_12m, sigma_ann}

      _ ->
        {0.0, 0.0}
    end
  end

  defp annualised_vol(prices) when length(prices) < 2, do: 0.0

  defp annualised_vol(prices) do
    rets =
      prices
      |> Enum.zip(tl(prices))
      |> Enum.reduce([], fn {prev, curr}, acc ->
        if prev > 0, do: [:math.log(curr / prev) | acc], else: acc
      end)

    case rets do
      [] ->
        0.0

      _ ->
        n = length(rets)
        m = Enum.sum(rets) / n
        var = Enum.reduce(rets, 0.0, fn r, a -> a + (r - m) * (r - m) end) / max(n - 1, 1)
        :math.sqrt(var) * :math.sqrt(252)
    end
  end

  # Config helpers ────────────────────────────────────────────────────────────

  defp resolve_list(config, key, env, default) do
    case Map.get(config, key) do
      list when is_list(list) and list != [] ->
        list

      _ ->
        case System.get_env(env) do
          nil -> default
          "" -> default
          str -> String.split(str, ",", trim: true) |> Enum.map(&String.trim/1)
        end
    end
  end

  defp resolve_float(config, key, env, default) do
    case Map.get(config, key) do
      n when is_number(n) ->
        n * 1.0

      _ ->
        case System.get_env(env) do
          nil ->
            default

          "" ->
            default

          str ->
            case Float.parse(str) do
              {f, _} -> f
              :error -> default
            end
        end
    end
  end

  defp resolve_int(config, key, env, default) do
    case Map.get(config, key) do
      n when is_integer(n) ->
        n

      _ ->
        case System.get_env(env) do
          nil ->
            default

          "" ->
            default

          str ->
            case Integer.parse(str) do
              {i, _} -> i
              :error -> default
            end
        end
    end
  end
end
