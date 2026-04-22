defmodule AlpacaTrader.Strategies.PairCointegration do
  @moduledoc """
  Placeholder Strategy wrapping the existing pair-cointegration pipeline.

  The legacy `AlpacaTrader.Engine` scan path remains the authority for
  pair trades until a deeper port lands. This module exists so the new
  StrategyRegistry + OrderRouter plumbing has a pair-strategy slot and
  a future migration target.

  Current behaviour: `scan/2` and `exits/2` return empty signal lists.
  Pair trades still execute via the existing scheduler → engine path,
  unchanged. New strategies (FundingBasisArb) emit real signals.
  """
  @behaviour AlpacaTrader.Strategy

  alias AlpacaTrader.Types.FeedSpec

  @impl true
  def id, do: :pair_cointegration

  @impl true
  def required_feeds,
    do: [%FeedSpec{venue: :alpaca, symbols: :whitelist, cadence: :minute}]

  @impl true
  def init(_config), do: {:ok, %{}}

  @impl true
  def scan(state, _ctx), do: {:ok, [], state}

  @impl true
  def exits(state, _ctx), do: {:ok, [], state}

  @impl true
  def on_fill(state, _fill), do: {:ok, state}
end
