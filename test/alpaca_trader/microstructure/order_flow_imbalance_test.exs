defmodule AlpacaTrader.Microstructure.OrderFlowImbalanceTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Microstructure.OrderFlowImbalance, as: OFI

  test "first quote returns zero and seeds prev" do
    s = OFI.new(20)
    {:ok, ofi, s2} = OFI.update(s, %{bid: 100.0, ask: 100.05, bid_size: 1000, ask_size: 1000})
    assert ofi == 0.0
    assert s2.prev_quote != nil
    assert s2.history == []
  end

  test "bid up + ask down → positive OFI" do
    s = OFI.new(20)
    {:ok, _, s} = OFI.update(s, %{bid: 100.0, ask: 100.05, bid_size: 1000, ask_size: 1000})
    {:ok, ofi, _} = OFI.update(s, %{bid: 100.01, ask: 100.04, bid_size: 1500, ask_size: 800})
    assert ofi > 0.0
  end

  test "bid down + ask up → negative OFI" do
    s = OFI.new(20)
    {:ok, _, s} = OFI.update(s, %{bid: 100.0, ask: 100.05, bid_size: 1000, ask_size: 1000})
    {:ok, ofi, _} = OFI.update(s, %{bid: 99.99, ask: 100.06, bid_size: 800, ask_size: 1500})
    assert ofi < 0.0
  end

  test "history capped at window size" do
    s = OFI.new(3)

    s =
      Enum.reduce(1..10, s, fn i, acc ->
        {:ok, _, s2} =
          OFI.update(acc, %{bid: 100.0 + i / 100, ask: 100.05 + i / 100, bid_size: 1000, ask_size: 1000})

        s2
      end)

    assert length(s.history) <= 3
  end

  test "normalised handles single-element history" do
    s = OFI.new(20)
    {:ok, _, s} = OFI.update(s, %{bid: 100.0, ask: 100.05, bid_size: 1000, ask_size: 1000})
    {:ok, _, s} = OFI.update(s, %{bid: 100.01, ask: 100.04, bid_size: 1500, ask_size: 800})
    norm = OFI.normalised(s)
    assert is_float(norm)
  end
end
