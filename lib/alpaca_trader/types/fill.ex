defmodule AlpacaTrader.Types.Fill do
  @type t :: %__MODULE__{
          order_id: String.t(), venue: atom, symbol: String.t(),
          side: :buy | :sell, qty: Decimal.t(), price: Decimal.t(),
          fee: Decimal.t(), ts: DateTime.t()
        }
  defstruct [:order_id, :venue, :symbol, :side, :qty, :price, :ts,
             fee: Decimal.new(0)]
end
