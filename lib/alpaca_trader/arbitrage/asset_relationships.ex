defmodule AlpacaTrader.Arbitrage.AssetRelationships do
  @moduledoc """
  Asset pair definitions for cascading arbitrage detection.
  Covers crypto, equities, and cross-asset-class pairs.
  Substitute = competitors/alternatives. Complement = structural links.
  """

  # ── CRYPTO PAIRS ───────────────────────────────────────────

  # Meme coins: fastest reversion (5-30 min), highest volatility
  @meme_pairs [
    {"DOGE/USD", "SHIB/USD"},
    {"DOGE/USD", "BONK/USD"},
    {"SHIB/USD", "BONK/USD"},
    {"DOGE/USD", "PEPE/USD"},
    {"SHIB/USD", "PEPE/USD"}
  ]

  # L1 competitors: moderate reversion (15-60 min)
  @l1_pairs [
    {"ETH/USD", "SOL/USD"},
    {"SOL/USD", "AVAX/USD"},
    {"ETH/USD", "AVAX/USD"},
    {"SOL/USD", "DOT/USD"},
    {"ETH/USD", "DOT/USD"}
  ]

  # BTC beta: tightest correlation, slowest reversion (30-120 min)
  @btc_pairs [
    {"BTC/USD", "ETH/USD"},
    {"BTC/USD", "LTC/USD"},
    {"BTC/USD", "SOL/USD"},
    {"BTC/USD", "BCH/USD"}
  ]

  # DeFi tokens
  @defi_pairs [
    {"UNI/USD", "LINK/USD"},
    {"LINK/USD", "AVAX/USD"},
    {"AAVE/USD", "UNI/USD"},
    {"CRV/USD", "AAVE/USD"}
  ]

  # Stablecoin-denominated (same asset, different quote currency)
  @stablecoin_pairs [
    {"BTC/USD", "BTC/USDT"},
    {"ETH/USD", "ETH/USDT"},
    {"DOGE/USD", "DOGE/USDT"},
    {"BTC/USDT", "BTC/USDC"},
    {"ETH/USDT", "ETH/USDC"}
  ]

  # ── EQUITY PAIRS ───────────────────────────────────────────

  @equity_pairs [
    {"AAPL", "MSFT"},
    {"NVDA", "AMD"},
    {"AMZN", "GOOGL"},
    {"META", "GOOGL"},
    {"MARA", "RIOT"},
    {"MARA", "CLSK"}
  ]

  # ── CROSS-ASSET PAIRS (crypto ↔ equity) ────────────────────

  @cross_asset_pairs [
    {"BTC/USD", "IBIT"},
    {"BTC/USD", "COIN"},
    {"BTC/USD", "MARA"},
    {"BTC/USD", "MSTR"},
    {"ETH/USD", "COIN"}
  ]

  # ── COMPLEMENT PAIRS (structural links) ─────────────────────

  @complement_pairs [
    {"AAPL", "TSM"},
    {"BTC/USD", "COIN"},
    {"NVDA", "TSM"}
  ]

  # ── ALL SUBSTITUTES ────────────────────────────────────────

  # Stablecoin pairs (USD↔USDT, USD↔USDC) require USDT/USDC inventory which
  # an Alpaca USD-cash account doesn't hold; the buy leg of any such pair
  # rejects with `insufficient balance`. Gate inclusion behind an env flag —
  # off by default — and re-enable when running on a venue that holds the
  # quote currency (Hyperliquid, KuCoin, etc.).
  defp stablecoin_pairs_active do
    if Application.get_env(:alpaca_trader, :enable_stablecoin_pairs, false),
      do: @stablecoin_pairs,
      else: []
  end

  defp substitute_pairs_dynamic do
    @meme_pairs ++
      @l1_pairs ++
      @btc_pairs ++
      @defi_pairs ++
      stablecoin_pairs_active() ++
      @equity_pairs ++
      @cross_asset_pairs
  end

  # ── PUBLIC API ─────────────────────────────────────────────

  def substitute_pairs, do: substitute_pairs_dynamic()
  def complement_pairs, do: @complement_pairs
  def meme_pairs, do: @meme_pairs
  def l1_pairs, do: @l1_pairs
  def btc_pairs, do: @btc_pairs
  def defi_pairs, do: @defi_pairs

  def all_symbols do
    (substitute_pairs_dynamic() ++ @complement_pairs)
    |> Enum.flat_map(fn {a, b} -> [a, b] end)
    |> Enum.uniq()
  end

  def substitutes_for(symbol) do
    substitute_pairs_dynamic()
    |> Enum.flat_map(fn
      {^symbol, other} -> [other]
      {other, ^symbol} -> [other]
      _ -> []
    end)
  end

  def complements_for(symbol) do
    @complement_pairs
    |> Enum.flat_map(fn
      {^symbol, other} -> [other]
      {other, ^symbol} -> [other]
      _ -> []
    end)
  end

  def has_relationships?(symbol) do
    substitutes_for(symbol) != [] or complements_for(symbol) != []
  end

  @doc "Returns the volatility tier for an asset (:meme, :high, :moderate, :equity)"
  def volatility_tier(symbol) do
    cond do
      Enum.any?(@meme_pairs, fn {a, b} -> a == symbol or b == symbol end) -> :meme
      Enum.any?(@l1_pairs, fn {a, b} -> a == symbol or b == symbol end) -> :high
      Enum.any?(@defi_pairs, fn {a, b} -> a == symbol or b == symbol end) -> :high
      Enum.any?(@btc_pairs, fn {a, b} -> a == symbol or b == symbol end) -> :moderate
      Enum.any?(@stablecoin_pairs, fn {a, b} -> a == symbol or b == symbol end) -> :moderate
      true -> :equity
    end
  end

  @doc "Returns tier-specific trading parameters."
  def params_for(symbol) do
    case volatility_tier(symbol) do
      :meme -> %{profit_target: 2.0, stop_loss: -1.5, z_entry: 1.8, max_hold: 30}
      :high -> %{profit_target: 1.2, stop_loss: -1.0, z_entry: 2.0, max_hold: 60}
      :moderate -> %{profit_target: 0.5, stop_loss: -0.5, z_entry: 2.0, max_hold: 120}
      :equity -> %{profit_target: 0.5, stop_loss: -2.0, z_entry: 2.0, max_hold: 20}
    end
  end
end
