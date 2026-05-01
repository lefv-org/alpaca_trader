defmodule AlpacaTrader.Strategies.VolBetaMeanReversion do
  @moduledoc """
  Volatility-beta mean reversion — ported from James Mawm's HFT model
  (github.com/jamesmawm/High-Frequency-Trading-Model-with-IB, 2 875 ★).

  ## Core idea

  For each configured pair (A, B) we compute two rolling statistics over a
  lookback window of recent closes:

    * **beta**           = mean(price_A) / mean(price_B)
    * **volatility_ratio** = std(pct_change(A)) / std(pct_change(B))

  From those we derive:

    * **expected_A** = beta × current_B
    * **uptrend**    = vol_ratio > 1  (A has been more volatile than B)
    * **downtrend**  = vol_ratio < 1

  Trade signals:

    | Condition                              | Action     |
    |----------------------------------------|------------|
    | uptrend AND price_A < expected_A       | BUY A      |
    | downtrend AND price_A > expected_A     | SELL A     |

  Rationale: when A's volatility dominates (uptrend) and A is momentarily
  *cheaper* than its long-run beta relationship predicts, mean reversion
  favours a recovery — go long.  Converse for downtrend + overpriced.

  In `LONG_ONLY_MODE=true` (default), the SELL signal is suppressed.

  ## Resolution

  Uses daily bars from BarsStore (populated by BarsSyncJob).  The window
  defaults to the most recent 60 bars.  With daily bars that is ~3 months of
  data.  Switching to minute or 5-minute bars via `MinuteBarCache` would
  tighten the lookback to hours.

  ## Configuration

    * `:pairs`           — list of `{sym_a, sym_b}` tuples (default: VBMR_PAIRS env)
    * `:window_bars`     — number of bars in the rolling window (default: 60)
    * `:min_bars`        — minimum bars required before signalling (default: 20)
    * `:entry_threshold` — fraction by which price must deviate from expected
                           before entering (default: 0.005, i.e. 0.5%)
  """

  @behaviour AlpacaTrader.Strategy

  require Logger

  alias AlpacaTrader.Types.{Signal, Leg, FeedSpec}
  alias AlpacaTrader.BarsStore

  @conviction 0.68
  @default_pairs [{"SPY", "QQQ"}, {"AAPL", "MSFT"}, {"GLD", "TLT"}, {"XLF", "XLK"}]

  # ── Strategy callbacks ────────────────────────────────────────────────────────

  @impl true
  def id, do: :vol_beta_mean_reversion

  @impl true
  def required_feeds do
    [%FeedSpec{venue: :alpaca, symbols: :whitelist, cadence: :minute}]
  end

  @impl true
  def init(config) do
    pairs = resolve_pairs(config)
    window = Map.get(config, :window_bars, 60)
    min_bars = Map.get(config, :min_bars, 20)
    threshold = Map.get(config, :entry_threshold, 0.005)

    state = %{
      pairs: pairs,
      window_bars: window,
      min_bars: min_bars,
      entry_threshold: threshold,
      # track open positions per pair: %{{"SPY","QQQ"} => :long | :short | nil}
      open_positions: %{}
    }

    Logger.info(
      "[VBMR] init pairs=#{length(pairs)} window=#{window} threshold=#{threshold}"
    )

    {:ok, state}
  end

  @impl true
  def scan(state, _ctx) do
    long_only = Application.get_env(:alpaca_trader, :long_only_mode, true)
    {signals, new_state} = evaluate_all_pairs(state, long_only)
    {:ok, signals, new_state}
  end

  @impl true
  def exits(state, _ctx), do: {:ok, [], state}

  @impl true
  def on_fill(state, _fill), do: {:ok, state}

  # ── Core logic ────────────────────────────────────────────────────────────────

  defp evaluate_all_pairs(state, long_only) do
    Enum.reduce(state.pairs, {[], state}, fn {sym_a, sym_b}, {sigs_acc, st} ->
      case fetch_closes(sym_a, sym_b, st.window_bars) do
        {:ok, closes_a, closes_b} ->
          case compute_signals(sym_a, sym_b, closes_a, closes_b, st, long_only) do
            nil ->
              {sigs_acc, st}

            signal ->
              new_open = Map.put(st.open_positions, {sym_a, sym_b}, signal_side(signal))
              {sigs_acc ++ [signal], %{st | open_positions: new_open}}
          end

        {:error, reason} ->
          Logger.debug("[VBMR] skipping #{sym_a}/#{sym_b}: #{inspect(reason)}")
          {sigs_acc, st}
      end
    end)
  end

  defp fetch_closes(sym_a, sym_b, window) do
    with {:ok, closes_a} <- BarsStore.get_closes(sym_a),
         {:ok, closes_b} <- BarsStore.get_closes(sym_b) do
      a = Enum.take(closes_a, -window)
      b = Enum.take(closes_b, -window)
      {:ok, a, b}
    else
      :error -> {:error, :missing_bars}
    end
  end

  defp compute_signals(sym_a, sym_b, closes_a, closes_b, state, long_only) do
    n = min(length(closes_a), length(closes_b))

    if n < state.min_bars do
      Logger.debug("[VBMR] #{sym_a}/#{sym_b} only #{n} bars, need #{state.min_bars}")
      nil
    else
      a = Enum.take(closes_a, -n)
      b = Enum.take(closes_b, -n)

      mean_a = mean(a)
      mean_b = mean(b)

      beta = if mean_b == 0.0, do: 1.0, else: mean_a / mean_b

      vol_a = pct_change_std(a)
      vol_b = pct_change_std(b)

      vol_ratio = if vol_b == 0.0, do: 1.0, else: vol_a / vol_b

      last_a = List.last(a)
      last_b = List.last(b)
      expected_a = beta * last_b

      deviation = if expected_a == 0.0, do: 0.0, else: abs(last_a - expected_a) / expected_a

      is_uptrend = vol_ratio > 1.0
      is_underpriced = last_a < expected_a  # A is cheaper than expected → buy
      is_overpriced = last_a > expected_a   # A is more expensive → sell

      already_open = Map.get(state.open_positions, {sym_a, sym_b})

      Logger.debug(
        "[VBMR] #{sym_a}/#{sym_b} beta=#{Float.round(beta, 4)} vr=#{Float.round(vol_ratio, 3)} " <>
          "last_A=#{last_a} expected_A=#{Float.round(expected_a, 4)} dev=#{Float.round(deviation, 4)}"
      )

      cond do
        # Entry gates: no existing position, deviation exceeds threshold.
        already_open != nil ->
          nil

        deviation < state.entry_threshold ->
          nil

        # BUY A: uptrend + A is underpriced relative to B
        is_uptrend and is_underpriced ->
          build_signal(sym_a, sym_b, :buy, beta, vol_ratio, last_a, expected_a)

        # SELL A: downtrend + A is overpriced relative to B (long-only blocks this)
        not long_only and not is_uptrend and is_overpriced ->
          build_signal(sym_a, sym_b, :sell, beta, vol_ratio, last_a, expected_a)

        true ->
          nil
      end
    end
  end

  defp build_signal(sym_a, sym_b, side, beta, vol_ratio, last_a, expected_a) do
    direction = if side == :buy, do: "underpriced", else: "overpriced"
    # Use the same notional sizing as FundingBasisArb: $50 per leg by default,
    # or the configured order_notional_pct applied to a nominal $10k equity.
    notional = Decimal.from_float(50.0)

    Signal.new(
      strategy: id(),
      conviction: @conviction,
      reason:
        "VBMR #{side} #{sym_a}/#{sym_b}: #{direction} " <>
          "beta=#{Float.round(beta, 3)} vr=#{Float.round(vol_ratio, 3)} " <>
          "last=#{last_a} expected=#{Float.round(expected_a, 4)}",
      ttl_ms: 300_000,
      legs: [
        %Leg{
          venue: :alpaca,
          symbol: sym_a,
          side: side,
          size: notional,
          size_mode: :notional,
          type: :market,
          limit_price: nil
        }
      ]
    )
  end

  defp signal_side(%{legs: [%{side: s} | _]}), do: s
  defp signal_side(_), do: nil

  # ── Stats helpers ─────────────────────────────────────────────────────────────

  defp mean([]), do: 0.0

  defp mean(list) do
    Enum.sum(list) / length(list)
  end

  # Standard deviation of percentage changes: std( (x_t - x_{t-1}) / x_{t-1} )
  defp pct_change_std(prices) when length(prices) < 2, do: 0.0

  defp pct_change_std(prices) do
    changes =
      prices
      |> Enum.zip(tl(prices))
      |> Enum.reduce([], fn {prev, curr}, acc ->
        if prev == 0.0, do: acc, else: [((curr - prev) / prev) | acc]
      end)

    case changes do
      [] -> 0.0
      _ -> std_dev(changes)
    end
  end

  defp std_dev(list) do
    n = length(list)

    if n < 2 do
      0.0
    else
      m = mean(list)
      variance = Enum.sum(Enum.map(list, fn x -> (x - m) * (x - m) end)) / (n - 1)
      :math.sqrt(variance)
    end
  end

  # ── Config helpers ────────────────────────────────────────────────────────────

  defp resolve_pairs(%{pairs: pairs}) when is_list(pairs) and pairs != [], do: pairs

  defp resolve_pairs(_config) do
    case System.get_env("VBMR_PAIRS") do
      nil ->
        @default_pairs

      csv ->
        csv
        |> String.split(";")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn pair_str ->
          case String.split(pair_str, ":") do
            [a, b] -> {String.trim(a), String.trim(b)}
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
    end
  end
end
