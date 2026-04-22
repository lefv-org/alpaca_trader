defmodule AlpacaTrader.Types.Bar do
  @type t :: %__MODULE__{
          venue: atom, symbol: String.t(),
          o: Decimal.t(), h: Decimal.t(), l: Decimal.t(), c: Decimal.t(),
          v: Decimal.t(), ts: DateTime.t(),
          timeframe: :minute | :hour | :day
        }
  defstruct [:venue, :symbol, :o, :h, :l, :c, :v, :ts, timeframe: :minute]
end
