defmodule AlpacaTrader.Arbitrage.HalfLifeManager do
  @moduledoc """
  Turn the Ornstein-Uhlenbeck half-life of a pair's spread into two
  operational levers:

  1. Time-stop: close any open position at `multiplier * half_life` bars
     regardless of z-score. A 2-day half-life pair held 30 bars is
     dead-money — the edge has decayed and carry costs eat the position.

  2. Size-by-half-life: scale notional inversely with half-life. Pairs
     that revert in 3 bars give you 10× the turnover of a 30-bar pair
     and should carry proportionally more capital for the same per-trade
     risk. Clamped to avoid runaway sizing on near-zero half-lives.

  All functions pure. Call `AlpacaTrader.Arbitrage.MeanReversion.half_life/1`
  upstream to get the input.
  """

  @default_time_stop_mult 2.0
  @default_reference_hl 10.0
  @default_min_mult 0.25
  @default_max_mult 2.0
  @default_fallback_bars 60

  @doc """
  How many bars to allow before force-closing.

  If `half_life` is nil or non-positive, returns `fallback_bars`
  (default #{@default_fallback_bars}).
  """
  def time_stop_bars(half_life, multiplier \\ @default_time_stop_mult, opts \\ [])

  def time_stop_bars(half_life, multiplier, _opts)
      when is_number(half_life) and half_life > 0 and is_number(multiplier) do
    trunc(Float.ceil(half_life * multiplier))
  end

  def time_stop_bars(_, _, opts),
    do: Keyword.get(opts, :fallback_bars, @default_fallback_bars)

  @doc """
  Notional multiplier relative to reference half-life.

  Proportional: `size_mult = reference_hl / half_life`, clamped to
  `[min_mult, max_mult]`. Returns 1.0 when `half_life` is nil or non-positive.

  ## Options
    * `:reference_half_life` - baseline half-life (default #{@default_reference_hl})
    * `:min_mult` - lower clamp (default #{@default_min_mult})
    * `:max_mult` - upper clamp (default #{@default_max_mult})
  """
  def size_multiplier(half_life, opts \\ [])

  def size_multiplier(half_life, opts) when is_number(half_life) and half_life > 0 do
    reference = Keyword.get(opts, :reference_half_life, @default_reference_hl)
    min_mult = Keyword.get(opts, :min_mult, @default_min_mult)
    max_mult = Keyword.get(opts, :max_mult, @default_max_mult)

    raw = reference / half_life
    raw |> max(min_mult) |> min(max_mult)
  end

  def size_multiplier(_, _), do: 1.0

  @doc """
  True if the position has been open >= `time_stop_bars(half_life, multiplier, opts)`.

  ## Options
    * `:half_life` - OU half-life (nil triggers fallback behavior)
    * `:multiplier` - time-stop multiplier (default #{@default_time_stop_mult})
    * `:fallback_bars` - used when half-life is nil/non-positive (default #{@default_fallback_bars})
  """
  def should_time_stop?(hold_bars, opts) when is_integer(hold_bars) and is_list(opts) do
    half_life = Keyword.get(opts, :half_life)
    mult = Keyword.get(opts, :multiplier, @default_time_stop_mult)
    hold_bars >= time_stop_bars(half_life, mult, opts)
  end
end
