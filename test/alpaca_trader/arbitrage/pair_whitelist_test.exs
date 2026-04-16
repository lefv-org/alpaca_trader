defmodule AlpacaTrader.Arbitrage.PairWhitelistTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.Arbitrage.PairWhitelist

  setup do
    tmp =
      System.tmp_dir!() <>
        "/pair_whitelist_test_#{:erlang.unique_integer([:positive])}.json"

    original_path = Application.get_env(:alpaca_trader, :pair_whitelist_path, "priv/runtime/pair_whitelist.json")

    Application.put_env(:alpaca_trader, :pair_whitelist_path, tmp)
    Application.put_env(:alpaca_trader, :pair_whitelist_enabled, true)

    PairWhitelist.set_path(tmp)

    on_exit(fn ->
      File.rm(tmp)
      # Restore the prod path so later tests/production runs don't get clobbered
      PairWhitelist.set_path(original_path)
      Application.put_env(:alpaca_trader, :pair_whitelist_path, original_path)
      Application.put_env(:alpaca_trader, :pair_whitelist_enabled, false)
    end)

    %{tmp: tmp}
  end

  test "empty whitelist allows all pairs (permissive default)" do
    assert PairWhitelist.size() == 0
    assert PairWhitelist.allowed?("BTC/USD", "ETH/USD")
    assert PairWhitelist.allowed?("DOGE/USD", "SHIB/USD")
  end

  test "populated whitelist allows listed pairs, rejects others" do
    PairWhitelist.replace([{"UNI/USD", "AAVE/USD"}, {"DOGE/USD", "DOGE/USDT"}])

    assert PairWhitelist.allowed?("UNI/USD", "AAVE/USD")
    assert PairWhitelist.allowed?("AAVE/USD", "UNI/USD"), "should be order-insensitive"
    assert PairWhitelist.allowed?("DOGE/USD", "DOGE/USDT")
    refute PairWhitelist.allowed?("BTC/USD", "ETH/USD")
    refute PairWhitelist.allowed?("BONK/USD", "PEPE/USD")
  end

  test "disabled gate is always permissive" do
    PairWhitelist.replace([{"UNI/USD", "AAVE/USD"}])
    Application.put_env(:alpaca_trader, :pair_whitelist_enabled, false)

    assert PairWhitelist.allowed?("BONK/USD", "anything")
  end

  test "persists to disk and reloads" do
    PairWhitelist.replace([{"A/USD", "B/USD"}, {"C/USD", "D/USD"}])
    assert PairWhitelist.size() == 2

    PairWhitelist.replace([])
    assert PairWhitelist.size() == 0

    PairWhitelist.reload()
    # After reload, we should read back the last persisted state (which is 0 pairs)
    assert PairWhitelist.size() == 0
  end

  test "accepts map input with string keys" do
    PairWhitelist.replace([
      %{"asset_a" => "UNI/USD", "asset_b" => "AAVE/USD"}
    ])

    assert PairWhitelist.allowed?("UNI/USD", "AAVE/USD")
  end
end
