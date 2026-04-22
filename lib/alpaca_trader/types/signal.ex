defmodule AlpacaTrader.Types.Leg do
  @moduledoc "One leg of a Signal. Carries venue + order primitives."

  @type t :: %__MODULE__{
          venue: atom,
          symbol: String.t(),
          side: :buy | :sell,
          size: number | Decimal.t(),
          size_mode: :qty | :notional | :pct_equity,
          type: :market | :limit,
          limit_price: Decimal.t() | nil
        }

  defstruct [:venue, :symbol, :side, :size, :size_mode, :type, :limit_price]
end

defmodule AlpacaTrader.Types.Signal do
  @moduledoc """
  Trade intent emitted by a Strategy. Carries one or more Legs routed by OrderRouter.
  """
  alias AlpacaTrader.Types.Leg

  @type t :: %__MODULE__{
          id: String.t(),
          strategy: atom,
          atomic: boolean,
          legs: [Leg.t()],
          conviction: float,
          reason: String.t(),
          ttl_ms: pos_integer,
          created_at: DateTime.t(),
          meta: map
        }

  defstruct [:strategy, :legs, :conviction, :reason, :ttl_ms,
             id: nil, atomic: true, created_at: nil, meta: %{}]

  @spec new(keyword) :: t()
  def new(opts) do
    id = Keyword.get(opts, :id) || generate_uuid()
    created_at = Keyword.get(opts, :created_at) || DateTime.utc_now()
    struct!(__MODULE__, Keyword.merge(opts, id: id, created_at: created_at))
  end

  @spec expired?(t(), DateTime.t()) :: boolean
  def expired?(%__MODULE__{created_at: created, ttl_ms: ttl}, now \\ DateTime.utc_now()) do
    DateTime.diff(now, created, :millisecond) > ttl
  end

  # UUID v4, no Ecto dep.
  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    # Set version + variant bits for v4.
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end
