defmodule AlpacaTrader.Types.Position do
  @type t :: %__MODULE__{
          venue: atom,
          symbol: String.t(),
          qty: Decimal.t(),
          avg_entry: Decimal.t() | nil,
          mark: Decimal.t() | nil,
          asset_class: :equity | :crypto | :perp | :unknown,
          opened_at: DateTime.t() | nil,
          raw: map
        }

  defstruct [:venue, :symbol, :qty, :avg_entry, :mark, :opened_at,
            asset_class: :unknown, raw: %{}]

  def market_value(%__MODULE__{qty: q, mark: m}) when not is_nil(m),
    do: Decimal.mult(q, m)
  def market_value(_), do: Decimal.new(0)

  def direction(%__MODULE__{qty: q}) do
    case Decimal.compare(q, 0) do
      :gt -> :long
      :lt -> :short
      :eq -> :flat
    end
  end
end
