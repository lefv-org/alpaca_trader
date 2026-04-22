defmodule AlpacaTrader.OrderRouterTest do
  use ExUnit.Case, async: false
  import Mox
  setup :verify_on_exit!

  alias AlpacaTrader.{OrderRouter, BrokerMock}
  alias AlpacaTrader.Types.{Signal, Leg, Order, Account, Capabilities}

  defp one_leg_signal(opts \\ []) do
    leg = %Leg{venue: :broker_mock, symbol: "AAPL", side: :buy,
               size: 100.0, size_mode: :notional, type: :market}
    Signal.new([{:strategy, :test}, {:legs, [leg]}, {:conviction, 1.0},
                {:reason, "t"}, {:ttl_ms, 10_000}] ++ opts)
  end

  setup do
    Application.put_env(:alpaca_trader, :brokers, broker_mock: BrokerMock,
                                                    alpaca: AlpacaTrader.Brokers.Alpaca)
    Application.put_env(:alpaca_trader, :trading_enabled, true)
    on_exit(fn -> Application.delete_env(:alpaca_trader, :trading_enabled) end)
    :ok
  end

  test "drops expired signal" do
    expired = one_leg_signal(ttl_ms: 1,
                             created_at: DateTime.add(DateTime.utc_now(), -10, :second))
    assert {:dropped, :expired} = OrderRouter.route(expired)
  end

  test "drops when TRADING_ENABLED is false" do
    Application.put_env(:alpaca_trader, :trading_enabled, false)
    assert {:dropped, :kill_switch} = OrderRouter.route(one_leg_signal())
  end

  test "drops on low conviction" do
    sig = one_leg_signal(conviction: 0.3)
    BrokerMock |> stub(:capabilities, fn ->
      %Capabilities{shorting: true, fractional: true, hours: :h24}
    end)
    assert {:dropped, :low_conviction} = OrderRouter.route(sig)
  end

  test "rejects atomic signal when venue lacks shorting capability" do
    leg_a = %Leg{venue: :broker_mock, symbol: "A", side: :buy,
                 size: 100.0, size_mode: :notional, type: :market}
    leg_b = %Leg{venue: :broker_mock, symbol: "B", side: :sell,
                 size: 100.0, size_mode: :notional, type: :market}
    sig = Signal.new(strategy: :t, legs: [leg_a, leg_b], conviction: 1.0,
                     reason: "t", ttl_ms: 10_000, atomic: true)
    BrokerMock |> stub(:capabilities, fn ->
      %Capabilities{shorting: false, fractional: true, hours: :h24}
    end)
    assert {:rejected, :venue_cannot_short} = OrderRouter.route(sig)
  end

  test "submits when all gates pass" do
    sig = one_leg_signal()
    BrokerMock |> stub(:capabilities, fn ->
      %Capabilities{shorting: true, fractional: true, hours: :h24}
    end)
    BrokerMock |> expect(:submit_order, fn %Order{} = o, _ ->
      {:ok, %{o | status: :filled, id: "x"}}
    end)
    assert {:ok, [order]} = OrderRouter.route(sig)
    assert order.status == :filled
  end

  test "atomic pair: reverses filled leg when other leg fails" do
    leg_a = %Leg{venue: :broker_mock, symbol: "A", side: :buy,
                 size: 100.0, size_mode: :notional, type: :market}
    leg_b = %Leg{venue: :broker_mock, symbol: "B", side: :buy,
                 size: 100.0, size_mode: :notional, type: :market}
    sig = Signal.new(strategy: :t, legs: [leg_a, leg_b], conviction: 1.0,
                     reason: "t", ttl_ms: 10_000, atomic: true)

    BrokerMock |> stub(:capabilities, fn ->
      %Capabilities{shorting: true, fractional: true, hours: :h24}
    end)

    BrokerMock |> expect(:submit_order, 3, fn
      %Order{symbol: "A"} = o, _ -> {:ok, %{o | status: :filled, id: "leg1"}}
      %Order{symbol: "B"} = _o, _ -> {:error, :rate_limited}
    end)

    assert {:atomic_break, _filled} = OrderRouter.route(sig)
  end
end
