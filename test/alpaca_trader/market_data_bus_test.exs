defmodule AlpacaTrader.MarketDataBusTest do
  use ExUnit.Case, async: false
  alias AlpacaTrader.MarketDataBus
  alias AlpacaTrader.Types.Tick

  setup do
    {:ok, pid} = MarketDataBus.start_link(name: :bus_test)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    [bus: :bus_test]
  end

  test "broadcasts to subscriber", %{bus: bus} do
    MarketDataBus.subscribe(bus, self())
    tick = %Tick{venue: :alpaca, symbol: "AAPL", last: Decimal.new("150"),
                 ts: DateTime.utc_now()}
    MarketDataBus.publish(bus, tick)
    assert_receive {:market_data, ^tick}, 500
  end

  test "multiple subscribers each receive event", %{bus: bus} do
    parent = self()
    sub_fn = fn ->
      MarketDataBus.subscribe(bus, self())
      receive do
        {:market_data, event} -> send(parent, {:got, self(), event})
      after
        1000 -> send(parent, {:timeout, self()})
      end
    end
    s1 = spawn(sub_fn)
    s2 = spawn(sub_fn)
    Process.sleep(50)
    event = %Tick{venue: :alpaca, symbol: "X", last: Decimal.new("1"), ts: DateTime.utc_now()}
    MarketDataBus.publish(bus, event)
    assert_receive {:got, ^s1, ^event}, 500
    assert_receive {:got, ^s2, ^event}, 500
  end

  test "removes subscriber on DOWN", %{bus: bus} do
    {pid, ref} = spawn_monitor(fn -> MarketDataBus.subscribe(bus, self()) end)
    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      500 -> flunk("subscriber never exited")
    end
    # After DOWN, publishing should not crash bus.
    event = %Tick{venue: :alpaca, symbol: "X", last: Decimal.new("1"), ts: DateTime.utc_now()}
    assert :ok = MarketDataBus.publish(bus, event)
  end
end
