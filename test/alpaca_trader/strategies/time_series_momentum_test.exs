defmodule AlpacaTrader.Strategies.TimeSeriesMomentumTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.Strategies.TimeSeriesMomentum
  alias AlpacaTrader.BarsStore

  setup do
    Application.put_env(:alpaca_trader, :long_only_mode, true)
    {:ok, state} = TimeSeriesMomentum.init(%{symbols: ["TST"], min_bars: 20, lookback_bars: 60})
    [state: state]
  end

  test "id is :time_series_momentum" do
    assert TimeSeriesMomentum.id() == :time_series_momentum
  end

  test "no signal when bars insufficient", %{state: state} do
    closes = Enum.map(0..5, fn i -> %{"t" => i, "c" => 100.0 + i} end)
    BarsStore.put_all_bars(%{"TST" => closes})
    {:ok, sigs, _} = TimeSeriesMomentum.scan(state, %{})
    assert sigs == []
  end

  test "emits BUY signal for monotonically rising series", %{state: state} do
    closes = Enum.map(0..69, fn i -> %{"t" => i, "c" => 100.0 + i * 0.5} end)
    BarsStore.put_all_bars(%{"TST" => closes})
    {:ok, sigs, _} = TimeSeriesMomentum.scan(state, %{})
    assert length(sigs) == 1
    [sig] = sigs
    [leg] = sig.legs
    assert leg.side == :buy
    assert leg.symbol == "TST"
  end

  test "no signal in long-only mode for negative momentum", %{state: state} do
    closes = Enum.map(0..69, fn i -> %{"t" => i, "c" => 200.0 - i * 0.5} end)
    BarsStore.put_all_bars(%{"TST" => closes})
    {:ok, sigs, _} = TimeSeriesMomentum.scan(state, %{})
    assert sigs == []
  end
end
