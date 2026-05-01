defmodule AlpacaTrader.Fees.Flat do
  @moduledoc """
  Flat per-trade fee regardless of size. Common at retail-style brokers
  and useful for stress-testing strategies under fixed-cost regimes.

  Opts:

    * `:fee` — Decimal or float, charge per fill (default 0.00)
  """
  @behaviour AlpacaTrader.Fees.Model

  @impl true
  def compute_fee(_fill, opts \\ []) do
    fee = Keyword.get(opts, :fee, 0.0)

    case fee do
      %Decimal{} = d -> d
      n when is_integer(n) -> Decimal.new(n)
      n when is_float(n) -> Decimal.from_float(n)
    end
  end
end
