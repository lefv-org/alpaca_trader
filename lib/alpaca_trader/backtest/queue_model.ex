defmodule AlpacaTrader.Backtest.QueueModel do
  @moduledoc """
  Queue-position fill probability models. Ported from hftbacktest's
  `src/backtest/models/queue.rs`.

  Optimistic top-of-book backtests routinely overstate live MM P&L by
  2-5x because they assume every resting order at the touch fills. In
  reality your order is at the *back* of the queue and only fills after
  the orders ahead of it are consumed.

  These models estimate the probability our resting order has advanced
  given a change in front/back queue size, so the simulator fills only
  the expected fraction.

  Behaviour:

      @callback fill_probability(state, change_in_size) :: float
      @callback advance(state, change_in_size) :: new_state

  state shape:

      %{front: integer, back: integer}

  `front` = aggregate size in front of our order (will fill before us);
  `back`  = aggregate size behind us (will fill after us).
  """

  @type state :: %{front: number, back: number}
  @callback fill_probability(state, change :: number) :: float
  @callback advance(state, change :: number) :: state
end
