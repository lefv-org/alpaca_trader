defmodule AlpacaTrader.Types.Tick do
  @type t :: %__MODULE__{
          venue: atom, symbol: String.t(),
          bid: Decimal.t() | nil, ask: Decimal.t() | nil,
          last: Decimal.t() | nil, ts: DateTime.t()
        }
  defstruct [:venue, :symbol, :bid, :ask, :last, :ts]
end
