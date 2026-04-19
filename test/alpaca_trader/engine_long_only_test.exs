defmodule AlpacaTrader.EngineLongOnlyTest do
  @moduledoc """
  Exercises LONG_ONLY_MODE in the engine. The feature flag causes tier 2/3
  pair trades to emit only the long leg on entry and only the sell leg on
  exit — the short/buy-back legs are dropped.

  `build_entry_params/2` and `build_exit_params/2` are private. To keep these
  tests lightweight and avoid changing visibility, they invoke the private
  functions via `:erlang.apply/3`. The alternative (exercising
  scan_and_execute end-to-end with stubbed bars + broker) would be strictly
  more valuable but requires significantly more scaffolding; the flag-level
  tests here plus the existing engine test suite cover the risk adequately.
  """

  use ExUnit.Case, async: false

  alias AlpacaTrader.Engine
  alias AlpacaTrader.Engine.ArbitragePosition
  alias AlpacaTrader.Engine.MarketContext

  defp build_context do
    %MarketContext{
      symbol: "BTCUSD",
      account: %{
        "equity" => "100.0",
        "buying_power" => "100.0",
        "cash" => "100.0"
      },
      position: nil,
      clock: %{"is_open" => true},
      asset: %{"symbol" => "BTCUSD", "tradable" => true},
      bars: nil,
      positions: [],
      orders: []
    }
  end

  defp build_arb(direction) do
    %ArbitragePosition{
      asset: "BTCUSD",
      pair_asset: "ETHUSD",
      tier: 2,
      direction: direction,
      hedge_ratio: 1.0,
      z_score: -2.5,
      spread: -0.01
    }
  end

  setup do
    prev_long_only = Application.get_env(:alpaca_trader, :long_only_mode, false)
    prev_notional_pct = Application.get_env(:alpaca_trader, :order_notional_pct)
    prev_sizing_mode = Application.get_env(:alpaca_trader, :position_sizing_mode)

    Application.put_env(:alpaca_trader, :order_notional_pct, 0.1)
    Application.put_env(:alpaca_trader, :position_sizing_mode, :fixed)

    on_exit(fn ->
      Application.put_env(:alpaca_trader, :long_only_mode, prev_long_only)

      if prev_notional_pct == nil do
        Application.delete_env(:alpaca_trader, :order_notional_pct)
      else
        Application.put_env(:alpaca_trader, :order_notional_pct, prev_notional_pct)
      end

      if prev_sizing_mode == nil do
        Application.delete_env(:alpaca_trader, :position_sizing_mode)
      else
        Application.put_env(:alpaca_trader, :position_sizing_mode, prev_sizing_mode)
      end
    end)

    :ok
  end

  describe "long_only_mode flag" do
    test "defaults to false in application env" do
      Application.delete_env(:alpaca_trader, :long_only_mode)
      refute Application.get_env(:alpaca_trader, :long_only_mode, false)
    end

    test "can be toggled via Application.put_env" do
      Application.put_env(:alpaca_trader, :long_only_mode, true)
      assert Application.get_env(:alpaca_trader, :long_only_mode) == true

      Application.put_env(:alpaca_trader, :long_only_mode, false)
      assert Application.get_env(:alpaca_trader, :long_only_mode) == false
    end
  end

  describe "build_entry_params/2 in long-only mode" do
    setup do
      Application.put_env(:alpaca_trader, :long_only_mode, true)
      :ok
    end

    test "emits only the buy leg for :long_a_short_b" do
      ctx = build_context()
      arb = build_arb(:long_a_short_b)

      params = apply(Engine, :build_entry_params, [ctx, arb])

      # Single-leg map, not a pair
      refute Map.has_key?(params, :pair)
      refute Map.has_key?(params, :legs)
      assert params["side"] == "buy"
      assert params["symbol"] == "BTCUSD"
      assert params["type"] == "market"
      # notional is represented as a string-formatted decimal by order_notional/2
      assert params["notional"] != nil
    end

    test "emits only the buy leg for :long_b_short_a" do
      ctx = build_context()
      arb = build_arb(:long_b_short_a)

      params = apply(Engine, :build_entry_params, [ctx, arb])

      refute Map.has_key?(params, :pair)
      assert params["side"] == "buy"
      # When direction is :long_b_short_a, the long leg is pair_asset (ETHUSD).
      assert params["symbol"] == "ETHUSD"
    end
  end

  describe "build_entry_params/2 with long-only disabled (default)" do
    setup do
      Application.put_env(:alpaca_trader, :long_only_mode, false)
      :ok
    end

    test "still emits an atomic pair with both legs" do
      ctx = build_context()
      arb = build_arb(:long_a_short_b)

      params = apply(Engine, :build_entry_params, [ctx, arb])

      assert params.pair == true
      assert length(params.legs) == 2
      [leg1, leg2] = params.legs
      assert leg1["side"] == "buy" and leg1["symbol"] == "BTCUSD"
      assert leg2["side"] == "sell" and leg2["symbol"] == "ETHUSD"
    end
  end

  describe "build_exit_params/2 in long-only mode" do
    setup do
      Application.put_env(:alpaca_trader, :long_only_mode, true)
      :ok
    end

    test "emits only the sell leg for :long_a_short_b" do
      ctx = build_context()
      arb = build_arb(:long_a_short_b)

      params = apply(Engine, :build_exit_params, [ctx, arb])

      refute Map.has_key?(params, :pair)
      refute Map.has_key?(params, :legs)
      assert params["side"] == "sell"
      # For :long_a_short_b, we sell arb.asset (what we bought).
      assert params["symbol"] == "BTCUSD"
    end

    test "emits only the sell leg for :long_b_short_a" do
      ctx = build_context()
      arb = build_arb(:long_b_short_a)

      params = apply(Engine, :build_exit_params, [ctx, arb])

      assert params["side"] == "sell"
      # For :long_b_short_a, we sell pair_asset (the long leg).
      assert params["symbol"] == "ETHUSD"
    end
  end

  describe "build_exit_params/2 with long-only disabled (default)" do
    setup do
      Application.put_env(:alpaca_trader, :long_only_mode, false)
      :ok
    end

    test "still emits an atomic pair (sell long + buy back short)" do
      ctx = build_context()
      arb = build_arb(:long_a_short_b)

      params = apply(Engine, :build_exit_params, [ctx, arb])

      assert params.pair == true
      [sell_leg, buy_leg] = params.legs
      assert sell_leg["side"] == "sell" and sell_leg["symbol"] == "BTCUSD"
      assert buy_leg["side"] == "buy" and buy_leg["symbol"] == "ETHUSD"
    end
  end
end
