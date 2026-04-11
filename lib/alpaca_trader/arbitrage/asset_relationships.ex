defmodule AlpacaTrader.Arbitrage.AssetRelationships do
  @moduledoc """
  Pure config module defining known asset pairs for cascading arbitrage.
  Substitute pairs move inversely (trade one when the other is mispriced).
  Complement pairs move together (co-integrated assets).
  """

  @substitute_pairs [
    {"AAPL", "MSFT"},
    {"NVDA", "AMD"},
    {"BTC/USD", "IBIT"},
    {"AMZN", "GOOGL"},
    {"BTC/USD", "COIN"}
  ]

  @complement_pairs [
    {"BTC/USD", "COIN"},
    {"AAPL", "TSM"}
  ]

  @doc "All substitute pairs."
  def substitute_pairs, do: @substitute_pairs

  @doc "All complement pairs."
  def complement_pairs, do: @complement_pairs

  @doc "Unique set of all symbols referenced in any relationship."
  def all_symbols do
    (@substitute_pairs ++ @complement_pairs)
    |> Enum.flat_map(fn {a, b} -> [a, b] end)
    |> Enum.uniq()
  end

  @doc "Returns substitute partners for a given symbol."
  def substitutes_for(symbol) do
    @substitute_pairs
    |> Enum.flat_map(fn
      {^symbol, other} -> [other]
      {other, ^symbol} -> [other]
      _ -> []
    end)
  end

  @doc "Returns complement partners for a given symbol."
  def complements_for(symbol) do
    @complement_pairs
    |> Enum.flat_map(fn
      {^symbol, other} -> [other]
      {other, ^symbol} -> [other]
      _ -> []
    end)
  end

  @doc "Returns true if the symbol appears in any relationship."
  def has_relationships?(symbol) do
    substitutes_for(symbol) != [] or complements_for(symbol) != []
  end
end
