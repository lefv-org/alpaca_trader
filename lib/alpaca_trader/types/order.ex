defmodule AlpacaTrader.Types.Order do
  @moduledoc """
  Normalized order shape, venue-agnostic. Brokers translate this to
  their native format on submit, and translate fills back to %Fill{}.
  """

  @sides [:buy, :sell]
  @types [:market, :limit]
  @size_modes [:qty, :notional, :pct_equity]

  @type side :: :buy | :sell
  @type type :: :market | :limit
  @type size_mode :: :qty | :notional | :pct_equity
  @type status :: :pending | :submitted | :partial | :filled | :canceled | :rejected

  @type t :: %__MODULE__{
          id: String.t() | nil,
          client_order_id: String.t() | nil,
          venue: atom,
          symbol: String.t(),
          side: side,
          type: type,
          size: Decimal.t(),
          size_mode: size_mode,
          limit_price: Decimal.t() | nil,
          tif: :day | :gtc | :ioc,
          status: status,
          submitted_at: DateTime.t() | nil,
          filled_size: Decimal.t(),
          avg_fill_price: Decimal.t() | nil,
          reason: String.t() | nil,
          raw: map
        }

  defstruct [
    :id, :client_order_id, :venue, :symbol, :side, :type, :size, :size_mode,
    :limit_price, :submitted_at, :avg_fill_price, :reason,
    tif: :day,
    status: :pending,
    filled_size: Decimal.new(0),
    raw: %{}
  ]

  @spec new(keyword) :: t()
  def new(opts) do
    side = Keyword.fetch!(opts, :side)
    unless side in @sides, do: raise(ArgumentError, "bad side #{inspect(side)}")
    type = Keyword.fetch!(opts, :type)
    unless type in @types, do: raise(ArgumentError, "bad type #{inspect(type)}")
    size_mode = Keyword.fetch!(opts, :size_mode)
    unless size_mode in @size_modes, do: raise(ArgumentError, "bad size_mode #{inspect(size_mode)}")
    struct!(__MODULE__, opts)
  end
end
