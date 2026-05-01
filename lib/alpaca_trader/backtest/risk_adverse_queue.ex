defmodule AlpacaTrader.Backtest.RiskAdverseQueue do
  @moduledoc """
  RiskAdverseQueueModel from hftbacktest. Pessimistic queue: assumes
  our order is always last. Fills only when the *entire* queue ahead
  has been consumed.

      P(fill) = 1 if front == 0 else 0

  Useful as a sanity-check lower bound on backtest fill rates. Realistic
  results live between this and PowerProbQueue.
  """
  @behaviour AlpacaTrader.Backtest.QueueModel

  @impl true
  def fill_probability(%{front: front}, _change, _opts \\ []) do
    if front <= 0, do: 1.0, else: 0.0
  end

  @impl true
  def advance(%{front: front, back: back} = _state, change, _opts \\ []) do
    new_front = max(front - max(change, 0.0), 0.0)
    %{front: new_front, back: back}
  end
end
