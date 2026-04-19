defmodule AlpacaTrader.Polymarket.MarketMapper do
  @moduledoc """
  Maps Polymarket events/markets to Alpaca tradeable symbols.
  """

  @mappings [
    # Crypto price brackets
    %{pattern: ~r/bitcoin.*price/i, symbols: ["BTC/USD"], type: :crypto_bracket},
    %{pattern: ~r/ethereum.*price/i, symbols: ["ETH/USD"], type: :crypto_bracket},
    %{pattern: ~r/solana.*price/i, symbols: ["SOL/USD"], type: :crypto_bracket},
    %{pattern: ~r/dogecoin.*price/i, symbols: ["DOGE/USD"], type: :crypto_bracket},

    # Crypto milestones
    %{
      pattern: ~r/btc|bitcoin.*\$?\d+k/i,
      symbols: ["BTC/USD", "IBIT", "MARA", "COIN"],
      type: :crypto_milestone
    },
    %{pattern: ~r/eth|ethereum.*\$?\d+/i, symbols: ["ETH/USD", "COIN"], type: :crypto_milestone},

    # Fed / rates
    %{
      pattern: ~r/fed.*rate.*cut/i,
      symbols: ["TLT", "IEF", "BND", "JPM", "BAC"],
      type: :fed_rate
    },
    %{pattern: ~r/fed.*rate.*hike/i, symbols: ["TLT", "IEF", "GS", "JPM"], type: :fed_rate},
    %{pattern: ~r/fomc|federal.*reserve/i, symbols: ["TLT", "SPY"], type: :fed_rate},

    # Recession / economy
    %{pattern: ~r/recession/i, symbols: ["SPY", "QQQ", "TLT"], type: :recession},
    %{pattern: ~r/inflation.*\d+%/i, symbols: ["TLT", "TIPS", "GLD"], type: :inflation},

    # Crypto companies
    %{pattern: ~r/microstrategy|mstr/i, symbols: ["MSTR", "BTC/USD"], type: :crypto_equity},
    %{pattern: ~r/coinbase/i, symbols: ["COIN", "BTC/USD", "ETH/USD"], type: :crypto_equity},

    # Tariff / trade policy
    %{pattern: ~r/tariff.*china/i, symbols: ["FXI", "KWEB", "BABA"], type: :tariff},
    %{pattern: ~r/tariff.*canada/i, symbols: ["EWC"], type: :tariff}
  ]

  @doc "Find Alpaca symbols that map to a Polymarket event title."
  def map_event(title) when is_binary(title) do
    @mappings
    |> Enum.filter(fn %{pattern: p} -> Regex.match?(p, title) end)
    |> Enum.flat_map(fn %{symbols: s, type: t} -> Enum.map(s, &{&1, t}) end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  @doc "Check if an event title maps to any tradeable symbol."
  def tradeable?(title), do: map_event(title) != []
end
