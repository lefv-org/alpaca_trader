defmodule AlpacaTrader.Types.Capabilities do
  @moduledoc """
  Static description of a broker venue.
  Returned by `Broker.capabilities/0`. The `OrderRouter` uses this to
  decide whether a Signal leg is routable to a venue.
  """

  @type hours :: :rth | :h24
  @type t :: %__MODULE__{
          shorting: boolean,
          perps: boolean,
          fractional: boolean,
          min_notional: Decimal.t(),
          fee_bps: non_neg_integer,
          hours: hours
        }

  defstruct shorting: false,
            perps: false,
            fractional: false,
            min_notional: Decimal.new(1),
            fee_bps: 0,
            hours: :rth

  @spec new(keyword) :: t()
  def new(opts \\ []) do
    struct!(__MODULE__, opts)
  end
end
