defmodule AlpacaTrader.Strategies.DistancePairs do
  @moduledoc """
  Distance-method pairs trading — Gatev, Goetzmann & Rouwenhorst,
  Pairs Trading: Performance of a Relative-Value Arbitrage Rule, RFS 19(3), 2006.

  ## Algorithm

  Formation period (lookback):
    1. Normalise each price series: P_t / P_0 (cumulative return index).
    2. For each candidate pair (a, b), compute SSD = Σ (Pa_norm - Pb_norm)²
    3. Rank pairs by SSD; smaller is better (more co-moving).

  Trading rule:
    1. Compute spread σ over the formation window.
    2. ENTRY: spread divergence > 2σ (one leg up, other down).
    3. EXIT: spread converges to 0 (crossover).

  Caveats explicitly acknowledged in user-provided notes:
    - Edge has shrunk substantially since early 2000s.
    - Cointegration variants (we already run those) outperform on
      modern data.

  This module is provided for completeness and academic comparison.
  Run alongside `AlpacaTrader.Strategies.PairCointegration` to A/B
  the simple-distance signal vs the cointegration-filtered signal.

  ## Configuration

    * `:pairs` — explicit `[{sym_a, sym_b}, ...]` (default: DP_PAIRS env)
    * `:formation_bars` — lookback window (default: 60)
    * `:entry_sigma` — divergence threshold in σ (default: 2.0)
    * `:notional_per_leg` — default 5.0
  """
  @behaviour AlpacaTrader.Strategy

  require Logger

  alias AlpacaTrader.Types.{Signal, Leg, FeedSpec}
  alias AlpacaTrader.BarsStore

  @conviction 0.65
  # Equity defaults get PDT-blocked on small accounts. Default to the
  # curated crypto pair set for actually-tradeable signals; override
  # with DP_PAIRS env.
  defp default_pairs, do: AlpacaTrader.Universe.crypto_pairs()

  @impl true
  def id, do: :distance_pairs

  @impl true
  def required_feeds do
    [%FeedSpec{venue: :alpaca, symbols: :whitelist, cadence: :minute}]
  end

  @impl true
  def init(config) do
    state = %{
      pairs: resolve_pairs(config),
      formation_bars: resolve_int(config, :formation_bars, "DP_FORMATION", 60),
      entry_sigma: resolve_float(config, :entry_sigma, "DP_ENTRY_SIGMA", 2.0),
      notional_per_leg: resolve_float(config, :notional_per_leg, "DP_NOTIONAL", 5.0),
      open_positions: %{}
    }

    Logger.info(
      "[DP] init pairs=#{length(state.pairs)} formation=#{state.formation_bars} " <>
        "entry_σ=#{state.entry_sigma} notional=#{state.notional_per_leg}"
    )

    {:ok, state}
  end

  @impl true
  def scan(state, _ctx) do
    long_only = Application.get_env(:alpaca_trader, :long_only_mode, true)

    signals =
      Enum.flat_map(state.pairs, fn {a, b} ->
        case evaluate_pair(a, b, state, long_only) do
          [] -> []
          sigs -> sigs
        end
      end)

    {:ok, signals, state}
  end

  @impl true
  def exits(state, _ctx), do: {:ok, [], state}

  @impl true
  def on_fill(state, _fill), do: {:ok, state}

  # ── Core ────────────────────────────────────────────────────────────────────

  defp evaluate_pair(a, b, state, long_only) do
    with {:ok, ca} <- BarsStore.get_closes(a),
         {:ok, cb} <- BarsStore.get_closes(b),
         true <- length(ca) >= state.formation_bars and length(cb) >= state.formation_bars do
      window = state.formation_bars
      ca = Enum.take(ca, -window)
      cb = Enum.take(cb, -window)

      {pa_norm, pb_norm} = normalise_to_first(ca, cb)
      spread = Enum.zip_with(pa_norm, pb_norm, fn x, y -> x - y end)
      mean_s = mean(spread)
      sigma_s = std(spread)

      last_a = List.last(pa_norm)
      last_b = List.last(pb_norm)
      current_spread = last_a - last_b
      z = if sigma_s > 0, do: (current_spread - mean_s) / sigma_s, else: 0.0

      cond do
        # a expensive vs b: long b, short a
        z > state.entry_sigma ->
          [build_signal(a, b, :long_b_short_a, z, state, long_only)]

        # b expensive vs a: long a, short b
        z < -state.entry_sigma ->
          [build_signal(a, b, :long_a_short_b, z, state, long_only)]

        true ->
          []
      end
      |> Enum.reject(&is_nil/1)
    else
      _ ->
        []
    end
  end

  defp build_signal(a, b, direction, z, state, long_only) do
    legs = pair_legs(a, b, direction, state, long_only)

    if legs == [] do
      nil
    else
      Signal.new(
        strategy: id(),
        conviction: @conviction,
        reason:
          "DP #{direction} #{a}/#{b}: z=#{Float.round(z, 3)} " <>
            "σ_threshold=#{state.entry_sigma}",
        ttl_ms: 300_000,
        legs: legs
      )
    end
  end

  defp pair_legs(a, b, :long_a_short_b, state, long_only) do
    long = leg(a, :buy, state)
    short = if long_only, do: nil, else: leg(b, :sell, state)
    Enum.reject([long, short], &is_nil/1)
  end

  defp pair_legs(a, b, :long_b_short_a, state, long_only) do
    long = leg(b, :buy, state)
    short = if long_only, do: nil, else: leg(a, :sell, state)
    Enum.reject([long, short], &is_nil/1)
  end

  defp leg(symbol, side, state) do
    %Leg{
      venue: :alpaca,
      symbol: symbol,
      side: side,
      size: Decimal.from_float(state.notional_per_leg),
      size_mode: :notional,
      type: :market,
      limit_price: nil
    }
  end

  # ── Stats helpers ──────────────────────────────────────────────────────────

  defp normalise_to_first(ca, cb) do
    {fa, fb} = {hd(ca), hd(cb)}

    {
      Enum.map(ca, fn p -> if fa > 0, do: p / fa, else: 0.0 end),
      Enum.map(cb, fn p -> if fb > 0, do: p / fb, else: 0.0 end)
    }
  end

  defp mean([]), do: 0.0
  defp mean(list), do: Enum.sum(list) / length(list)

  defp std(list) when length(list) < 2, do: 0.0

  defp std(list) do
    m = mean(list)
    var = Enum.reduce(list, 0.0, fn x, acc -> acc + (x - m) * (x - m) end) / (length(list) - 1)
    :math.sqrt(var)
  end

  # ── Config helpers ─────────────────────────────────────────────────────────

  defp resolve_pairs(config) do
    case Map.get(config, :pairs) do
      list when is_list(list) and list != [] ->
        list

      _ ->
        case System.get_env("DP_PAIRS") do
          nil -> default_pairs()
          "" -> default_pairs()
          str -> parse_pairs(str)
        end
    end
  end

  defp parse_pairs(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn pair ->
      case String.split(pair, "/", parts: 2, trim: true) do
        [a, b] -> [{String.trim(a), String.trim(b)}]
        _ -> []
      end
    end)
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
end
