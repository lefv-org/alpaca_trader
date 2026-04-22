defmodule AlpacaTrader.Types.FeedSpec do
  @moduledoc """
  Strategies declare data feeds they need via `required_feeds/0`.
  MarketDataBus ensures the corresponding broker stream is subscribed.
  """
  @type t :: %__MODULE__{
          venue: atom,
          symbols: [String.t()] | :whitelist | :all,
          cadence: :tick | :second | :minute | :hour
        }
  defstruct [:venue, symbols: :whitelist, cadence: :minute]
end
