defmodule AlpacaTrader.Types.SignalTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.Types.{Signal, Leg}

  test "new/1 assigns uuid if missing, defaults atomic=true" do
    leg = %Leg{venue: :alpaca, symbol: "AAPL", side: :buy, size: 10.0,
               size_mode: :notional, type: :market}
    sig = Signal.new(strategy: :pair_cointegration, legs: [leg], conviction: 0.7,
                     reason: "ok", ttl_ms: 1000)
    assert sig.id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
    assert sig.atomic == true
    assert sig.strategy == :pair_cointegration
    assert length(sig.legs) == 1
    assert %DateTime{} = sig.created_at
  end

  test "new/1 honors supplied id and created_at" do
    leg = %Leg{venue: :alpaca, symbol: "AAPL", side: :buy, size: 10.0,
               size_mode: :notional, type: :market}
    ts = DateTime.utc_now()
    sig = Signal.new(id: "custom-id", created_at: ts, strategy: :s, legs: [leg],
                     conviction: 1.0, reason: "x", ttl_ms: 100)
    assert sig.id == "custom-id"
    assert sig.created_at == ts
  end

  test "expired?/2 true when age > ttl" do
    leg = %Leg{venue: :alpaca, symbol: "AAPL", side: :buy, size: 10.0,
               size_mode: :notional, type: :market}
    old = Signal.new(strategy: :s, legs: [leg], conviction: 1.0, reason: "o",
                     ttl_ms: 1, created_at: DateTime.add(DateTime.utc_now(), -5, :second))
    assert Signal.expired?(old)
  end

  test "expired?/2 false when fresh" do
    leg = %Leg{venue: :alpaca, symbol: "AAPL", side: :buy, size: 10.0,
               size_mode: :notional, type: :market}
    fresh = Signal.new(strategy: :s, legs: [leg], conviction: 1.0, reason: "o",
                       ttl_ms: 60_000)
    refute Signal.expired?(fresh)
  end
end
