defmodule AlpacaTrader.UniverseTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Universe

  test "crypto/0 returns all tiers combined" do
    list = Universe.crypto()
    assert "BTC/USD" in list
    assert "ETH/USD" in list
    assert "DOGE/USD" in list
  end

  test "crypto_tier1/0 returns just BTC + ETH" do
    assert Universe.crypto_tier1() == ["BTC/USD", "ETH/USD"]
  end

  test "crypto_pairs/0 returns curated tuples" do
    pairs = Universe.crypto_pairs()
    assert {"BTC/USD", "ETH/USD"} in pairs
    assert Enum.all?(pairs, fn {a, b} -> is_binary(a) and is_binary(b) end)
  end

  test "crypto_from_env honours CRYPTO_UNIVERSE override" do
    System.put_env("CRYPTO_UNIVERSE", "FOO/USD,BAR/USD")
    assert Universe.crypto_from_env() == ["FOO/USD", "BAR/USD"]
    System.delete_env("CRYPTO_UNIVERSE")
  end

  test "crypto_from_env returns liquid set when env unset" do
    System.delete_env("CRYPTO_UNIVERSE")
    assert "BTC/USD" in Universe.crypto_from_env()
  end

  test "crypto_pairs_from_env honours CRYPTO_PAIRS override" do
    System.put_env("CRYPTO_PAIRS", "FOO/USD-BAR/USD,BAZ/USD-QUX/USD")
    pairs = Universe.crypto_pairs_from_env()
    assert {"FOO/USD", "BAR/USD"} in pairs
    System.delete_env("CRYPTO_PAIRS")
  end
end
