defmodule AlpacaTrader.Arbitrage.AssetRelationshipsTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Arbitrage.AssetRelationships

  describe "substitute_pairs/0" do
    test "returns a non-empty list of tuples" do
      pairs = AssetRelationships.substitute_pairs()
      assert is_list(pairs) and length(pairs) > 0
      assert Enum.all?(pairs, fn {a, b} -> is_binary(a) and is_binary(b) end)
    end

    test "includes known pair" do
      assert {"AAPL", "MSFT"} in AssetRelationships.substitute_pairs()
    end
  end

  describe "complement_pairs/0" do
    test "returns a non-empty list of tuples" do
      pairs = AssetRelationships.complement_pairs()
      assert is_list(pairs) and length(pairs) > 0
    end

    test "includes known pair" do
      assert {"BTC/USD", "COIN"} in AssetRelationships.complement_pairs()
    end
  end

  describe "all_symbols/0" do
    test "returns unique list of all symbols" do
      symbols = AssetRelationships.all_symbols()
      assert is_list(symbols)
      assert "AAPL" in symbols
      assert "MSFT" in symbols
      assert "BTC/USD" in symbols
      assert "COIN" in symbols
      assert "TSM" in symbols
      # Verify uniqueness
      assert length(symbols) == length(Enum.uniq(symbols))
    end
  end

  describe "substitutes_for/1" do
    test "returns partners for AAPL" do
      assert "MSFT" in AssetRelationships.substitutes_for("AAPL")
    end

    test "returns partners for MSFT (reverse lookup)" do
      assert "AAPL" in AssetRelationships.substitutes_for("MSFT")
    end

    test "returns multiple partners for BTC/USD" do
      subs = AssetRelationships.substitutes_for("BTC/USD")
      assert "IBIT" in subs
      assert "COIN" in subs
    end

    test "returns empty list for unknown symbol" do
      assert AssetRelationships.substitutes_for("UNKNOWN") == []
    end
  end

  describe "complements_for/1" do
    test "returns partners for BTC/USD" do
      assert "COIN" in AssetRelationships.complements_for("BTC/USD")
    end

    test "returns partners for AAPL" do
      assert "TSM" in AssetRelationships.complements_for("AAPL")
    end

    test "returns empty list for symbol without complements" do
      assert AssetRelationships.complements_for("GOOGL") == []
    end
  end

  describe "has_relationships?/1" do
    test "returns true for symbol with substitutes" do
      assert AssetRelationships.has_relationships?("AAPL")
    end

    test "returns true for symbol with complements only" do
      assert AssetRelationships.has_relationships?("TSM")
    end

    test "returns false for unknown symbol" do
      refute AssetRelationships.has_relationships?("UNKNOWN")
    end
  end
end
