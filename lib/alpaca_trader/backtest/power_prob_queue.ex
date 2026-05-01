defmodule AlpacaTrader.Backtest.PowerProbQueue do
  @moduledoc """
  PowerProbQueueFunc3 from hftbacktest:

      P(fill) = 1 - (front / (front + back))^n

  Larger `n` ⇒ less optimistic about fills (queue depth matters more).
  Default `n=3` matches the hftbacktest example notebooks.

  Advance step splits the queue size change between consumed-from-front
  and added-at-back according to the fill probability:

      est_front = front - (1-prob)·change + max(back - prob·change, 0)
      est_back  = ...

  Use as a behaviour implementation:

      AlpacaTrader.Backtest.PowerProbQueue.fill_probability(
        %{front: 1000, back: 500}, change_in_size = 200, n: 3
      )
  """
  @behaviour AlpacaTrader.Backtest.QueueModel

  @default_n 3

  @impl true
  def fill_probability(%{front: front, back: back}, _change, opts \\ []) do
    n = Keyword.get(opts, :n, @default_n)
    total = front + back

    if total <= 0 do
      1.0
    else
      ratio = front / total
      1.0 - :math.pow(ratio, n)
    end
  end

  @impl true
  def advance(%{front: front, back: back} = state, change, opts \\ []) do
    prob = fill_probability(state, change, opts)

    new_front = front - (1.0 - prob) * change
    new_back = max(back - prob * change, 0.0)

    %{front: max(new_front, 0.0), back: new_back}
  end
end
