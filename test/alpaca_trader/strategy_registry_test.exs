defmodule AlpacaTrader.StrategyRegistryTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.StrategyRegistry

  defmodule FakeStrategy do
    @behaviour AlpacaTrader.Strategy
    alias AlpacaTrader.Types.Signal
    alias AlpacaTrader.Types.Leg

    def id, do: :fake_strategy_test
    def required_feeds, do: []
    def init(_), do: {:ok, %{count: 0}}

    def scan(state, _ctx) do
      leg = %Leg{venue: :alpaca, symbol: "TEST", side: :buy,
                 size: 10.0, size_mode: :notional, type: :market}
      sig = Signal.new(strategy: id(), legs: [leg], conviction: 1.0,
                       reason: "tick #{state.count}", ttl_ms: 1000)
      {:ok, [sig], %{state | count: state.count + 1}}
    end

    def exits(state, _ctx), do: {:ok, [], state}
    def on_fill(state, _fill), do: {:ok, state}
  end

  defmodule EmptyStrategy do
    @behaviour AlpacaTrader.Strategy
    def id, do: :empty_test
    def required_feeds, do: []
    def init(_), do: {:ok, %{}}
    def scan(state, _ctx), do: {:ok, [], state}
    def exits(state, _ctx), do: {:ok, [], state}
    def on_fill(state, _fill), do: {:ok, state}
  end

  setup do
    :ok
  end

  test "tick/1 returns signals from all strategies" do
    {:ok, _reg} = StrategyRegistry.start_link(name: :registry_test,
                                               strategies: [{FakeStrategy, %{}}, {EmptyStrategy, %{}}])
    signals = StrategyRegistry.tick(:registry_test, %{now: DateTime.utc_now()})
    assert is_list(signals)
    assert Enum.any?(signals, &(&1.strategy == :fake_strategy_test))
  end

  test "loaded_ids/1 returns strategy atom ids" do
    {:ok, _reg} = StrategyRegistry.start_link(name: :registry_test2,
                                               strategies: [{FakeStrategy, %{}}, {EmptyStrategy, %{}}])
    ids = StrategyRegistry.loaded_ids(:registry_test2)
    assert :fake_strategy_test in ids
    assert :empty_test in ids
  end
end
