defmodule AlpacaTrader.Strategies.AvellanedaStoikovTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.Strategies.AvellanedaStoikov
  alias AlpacaTrader.BarsStore

  setup do
    # Seed BarsStore with synthetic stable price history (returns ≈ 0).
    closes =
      Enum.map(0..29, fn i -> %{"t" => i, "c" => 100.0 + :math.sin(i / 10.0) * 0.5} end)

    BarsStore.put_all_bars(%{"AAPL" => closes, "SPY" => closes})

    Application.put_env(:alpaca_trader, :long_only_mode, true)

    {:ok, state} =
      AvellanedaStoikov.init(%{
        symbols: ["AAPL"],
        gamma: 0.1,
        kappa: 1.5,
        notional_per_leg: 5.0,
        target_inventory: 20.0,
        window_bars: 30,
        min_bars: 20
      })

    [state: state]
  end

  test "id is :avellaneda_stoikov" do
    assert AvellanedaStoikov.id() == :avellaneda_stoikov
  end

  @tag :skip
  test "no signal when bars missing", %{state: state} do
    state = %{state | symbols: ["MISSING_SYM"]}
    ctx = %{positions: %{}}
    {:ok, signals, _new_state} = AvellanedaStoikov.scan(state, ctx)
    assert is_list(signals)
  end

  test "init sets defaults from config map", %{state: state} do
    assert state.gamma == 0.1
    assert state.kappa == 1.5
    assert state.notional_per_leg == 5.0
    assert state.target_inventory == 20.0
    assert state.symbols == ["AAPL"]
  end

  test "on_fill increments inventory tally for buy" do
    {:ok, state} = AvellanedaStoikov.init(%{symbols: ["AAPL"]})
    fill = %{symbol: "AAPL", side: :buy}
    {:ok, new_state} = AvellanedaStoikov.on_fill(state, fill)
    assert Map.get(new_state.open_positions, "AAPL") == 1

    {:ok, state2} = AvellanedaStoikov.on_fill(new_state, fill)
    assert Map.get(state2.open_positions, "AAPL") == 2
  end

  test "on_fill decrements for sell" do
    {:ok, state} = AvellanedaStoikov.init(%{symbols: ["AAPL"]})
    fill = %{symbol: "AAPL", side: :sell}
    {:ok, new_state} = AvellanedaStoikov.on_fill(state, fill)
    assert Map.get(new_state.open_positions, "AAPL") == -1
  end

  test "required_feeds returns alpaca minute" do
    [feed] = AvellanedaStoikov.required_feeds()
    assert feed.venue == :alpaca
    assert feed.cadence == :minute
  end
end
