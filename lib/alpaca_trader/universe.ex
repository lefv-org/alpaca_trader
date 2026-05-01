defmodule AlpacaTrader.Universe do
  @moduledoc """
  Single source of truth for the crypto + equity universes the bot
  trades against. Strategies pull from here so a curated change in
  one place propagates to every signal generator.

  ## Why curated, not discovery-driven

  Pair-discovery against the full Alpaca universe (12k+ assets)
  produces high-recall noise: every two stocks with ~similar beta
  test as cointegrated by chance. Curated sector clusters concentrate
  the search where mean-reversion / momentum has documented edge.

  ## Crypto liquidity tiers

  Tier 1 (deep books, 24/7): BTC/USD, ETH/USD
  Tier 2 (liquid majors): LTC/USD, BCH/USD, AVAX/USD, LINK/USD,
                           UNI/USD, AAVE/USD
  Tier 3 (smaller but tradeable on Alpaca paper): DOT/USD, MKR/USD,
                           YFI/USD, GRT/USD, SUSHI/USD, BAT/USD,
                           CRV/USD, XTZ/USD, DOGE/USD

  ## Pair clusters (cointegration-likely)

  Within-cluster pairs are more likely to be cointegrated because
  they share fundamental price drivers (BTC dominance, L1 narrative,
  DeFi TVL).
  """

  @crypto_tier1 ~w[BTC/USD ETH/USD]
  @crypto_tier2 ~w[LTC/USD BCH/USD AVAX/USD LINK/USD UNI/USD AAVE/USD]
  @crypto_tier3 ~w[DOT/USD MKR/USD YFI/USD GRT/USD SUSHI/USD BAT/USD CRV/USD XTZ/USD DOGE/USD]

  # Sector clusters used for pair generation. Each cluster defines a
  # set of symbols whose internal pairs are candidates for distance /
  # cointegration / VBMR strategies.
  @clusters %{
    majors: ~w[BTC/USD ETH/USD],
    forks: ~w[LTC/USD BCH/USD],
    l1_alts: ~w[AVAX/USD DOT/USD],
    defi_blue: ~w[UNI/USD AAVE/USD MKR/USD],
    oracles: ~w[LINK/USD GRT/USD],
    dex: ~w[UNI/USD SUSHI/USD CRV/USD]
  }

  # Curated cointegration-likely pairs. Each {a, b} should share a
  # narrative driver. Pairs are NOT symmetric — bias toward the more
  # liquid leg as `a`.
  @curated_pairs [
    {"BTC/USD", "ETH/USD"},
    {"ETH/USD", "BCH/USD"},
    {"LTC/USD", "BCH/USD"},
    {"AVAX/USD", "DOT/USD"},
    {"LINK/USD", "GRT/USD"},
    {"UNI/USD", "SUSHI/USD"},
    {"UNI/USD", "AAVE/USD"},
    {"AAVE/USD", "MKR/USD"}
  ]

  @doc "All curated crypto USD pairs across all tiers."
  def crypto, do: @crypto_tier1 ++ @crypto_tier2 ++ @crypto_tier3

  @doc "Top-tier (deepest book) crypto for high-frequency strategies."
  def crypto_tier1, do: @crypto_tier1

  @doc "Tier 1 + Tier 2 — sweet spot for minute-cadence strategies."
  def crypto_liquid, do: @crypto_tier1 ++ @crypto_tier2

  @doc "All sector clusters as {name, symbols} pairs."
  def clusters, do: @clusters

  @doc "Curated pair list for pair-trading strategies (DistancePairs, VBMR)."
  def crypto_pairs, do: @curated_pairs

  @doc """
  Override-aware lookup: respects CRYPTO_UNIVERSE env if set, else
  falls back to the curated list. Single env knob for ops.
  """
  def crypto_from_env do
    case System.get_env("CRYPTO_UNIVERSE") do
      nil ->
        crypto_liquid()

      "" ->
        crypto_liquid()

      str ->
        str
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
    end
  end

  @doc """
  Override-aware pair list: respects CRYPTO_PAIRS env (format
  \"BTC/USD-ETH/USD,LTC/USD-BCH/USD\") else curated list.
  """
  def crypto_pairs_from_env do
    case System.get_env("CRYPTO_PAIRS") do
      nil ->
        crypto_pairs()

      "" ->
        crypto_pairs()

      str ->
        str
        |> String.split(",", trim: true)
        |> Enum.flat_map(fn p ->
          case String.split(p, "-", parts: 2, trim: true) do
            [a, b] -> [{String.trim(a), String.trim(b)}]
            _ -> []
          end
        end)
    end
  end
end
