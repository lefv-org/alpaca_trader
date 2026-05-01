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

  @doc """
  Default symbol set: minimal — BTC/USD + ETH/USD only.

  This is what every strategy gets when no env override is set. On a
  small (sub-$25k) paper account, concentrating on the two deepest-book
  USD pairs is strictly better than spraying signals across 17+
  symbols: less LLM-gate spend, fewer ghost/orphan edge cases, real
  execution depth on each instrument. Operators who actually want
  breadth should set CRYPTO_UNIVERSE explicitly.
  """
  def crypto, do: @crypto_tier1

  @doc "Same as crypto/0 — minimal default. Kept for symmetry."
  def crypto_tier1, do: @crypto_tier1

  @doc "Same as crypto/0. Operators wanting Tier 2 should opt in via env."
  def crypto_liquid, do: @crypto_tier1

  @doc "Tier 2 symbols (LTC, BCH, AVAX, LINK, UNI, AAVE) — opt-in."
  def crypto_tier2, do: @crypto_tier2

  @doc "Tier 3 symbols — opt-in only via CRYPTO_UNIVERSE."
  def crypto_tier3, do: @crypto_tier3

  @doc "Full curated set across all tiers — opt-in via CRYPTO_UNIVERSE=full."
  def crypto_full, do: @crypto_tier1 ++ @crypto_tier2 ++ @crypto_tier3

  @doc "All sector clusters as {name, symbols} pairs."
  def clusters, do: @clusters

  @doc """
  Default pair list: minimal — just BTC/USD ↔ ETH/USD.

  See `crypto/0` for rationale. Operators wanting more pairs should
  override via CRYPTO_PAIRS or per-strategy env (DP_PAIRS, VBMR_PAIRS).
  """
  def crypto_pairs, do: [{"BTC/USD", "ETH/USD"}]

  @doc "Full curated pair list — opt-in via CRYPTO_PAIRS=full."
  def crypto_pairs_full, do: @curated_pairs

  @doc """
  Override-aware lookup: respects CRYPTO_UNIVERSE env if set, else
  falls back to the curated list. Single env knob for ops.
  """
  def crypto_from_env do
    case System.get_env("CRYPTO_UNIVERSE") do
      nil -> crypto()
      "" -> crypto()
      "tier1" -> crypto_tier1()
      "tier2" -> crypto_tier2()
      "liquid" -> crypto_tier1() ++ crypto_tier2()
      "full" -> crypto_full()
      str -> str |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
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

      "full" ->
        crypto_pairs_full()

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
