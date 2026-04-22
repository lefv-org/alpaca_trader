defmodule AlpacaTrader.Brokers.Alpaca.Symbol do
  @moduledoc "Alpaca uses 'BTC/USD' for crypto; normalize across codebase."
  def to_alpaca(sym), do: sym
  def from_alpaca(sym), do: sym
end
