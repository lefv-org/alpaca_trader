defmodule AlpacaTrader.AltData.Signal do
  @moduledoc "Normalized alternative data signal from any provider."

  @derive Jason.Encoder
  defstruct [
    :provider,
    :signal_type,
    :direction,
    :strength,
    :affected_symbols,
    :reason,
    :fetched_at,
    :expires_at,
    :raw
  ]

  @type t :: %__MODULE__{
          provider: atom(),
          signal_type: atom(),
          direction: :bullish | :bearish | :neutral | :risk_off | :risk_on,
          strength: float(),
          affected_symbols: [String.t()],
          reason: String.t(),
          fetched_at: DateTime.t(),
          expires_at: DateTime.t(),
          raw: map()
        }
end
