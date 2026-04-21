defmodule AlpacaTrader.Types.Account do
  @type t :: %__MODULE__{
          venue: atom,
          equity: Decimal.t(),
          cash: Decimal.t(),
          buying_power: Decimal.t(),
          daytrade_count: non_neg_integer,
          pattern_day_trader: boolean,
          currency: String.t(),
          raw: map
        }
  defstruct [:venue, :equity, :cash, :buying_power,
             daytrade_count: 0, pattern_day_trader: false,
             currency: "USD", raw: %{}]
end
