defmodule AlpacaTrader.GainAccumulatorStoreTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.GainAccumulatorStore

  setup do
    tmp = System.tmp_dir!() <> "/gain_acc_test_#{:erlang.unique_integer([:positive])}.json"
    Application.put_env(:alpaca_trader, :gain_accumulator_path, tmp)
    Application.put_env(:alpaca_trader, :order_notional, "10")
    start_supervised!(GainAccumulatorStore)
    on_exit(fn -> File.rm(tmp) end)
    %{tmp: tmp}
  end

  test "first call snapshots principal and returns false", %{tmp: tmp} do
    refute GainAccumulatorStore.allow_entry?(100.0)
    assert GainAccumulatorStore.principal() == 100.0
    assert File.exists?(tmp)
    assert {:ok, %{"principal" => 100.0}} = Jason.decode(File.read!(tmp))
  end

  test "blocks entry when gain < order_notional" do
    GainAccumulatorStore.allow_entry?(100.0)
    refute GainAccumulatorStore.allow_entry?(105.0)
  end

  test "allows entry when gain >= order_notional" do
    GainAccumulatorStore.allow_entry?(100.0)
    assert GainAccumulatorStore.allow_entry?(110.0)
  end

  test "returns false when equity is nil" do
    GainAccumulatorStore.allow_entry?(100.0)
    refute GainAccumulatorStore.allow_entry?(nil)
  end

  test "trading_capital returns 0.0 before snapshot" do
    assert GainAccumulatorStore.trading_capital(120.0) == 0.0
  end

  test "trading_capital returns equity minus principal after snapshot" do
    GainAccumulatorStore.allow_entry?(100.0)
    assert GainAccumulatorStore.trading_capital(115.0) == 15.0
  end

  test "trading_capital floors at 0.0 when equity below principal" do
    GainAccumulatorStore.allow_entry?(100.0)
    assert GainAccumulatorStore.trading_capital(95.0) == 0.0
  end

  test "reset clears principal and deletes file", %{tmp: tmp} do
    GainAccumulatorStore.allow_entry?(100.0)
    assert File.exists?(tmp)
    GainAccumulatorStore.reset()
    assert GainAccumulatorStore.principal() == nil
    refute File.exists?(tmp)
  end

  test "reloads principal from file after restart", %{tmp: tmp} do
    GainAccumulatorStore.allow_entry?(99.0)
    assert File.exists?(tmp)

    stop_supervised!(GainAccumulatorStore)
    start_supervised!(GainAccumulatorStore)

    assert GainAccumulatorStore.principal() == 99.0
  end

  test "corrupt file starts with nil principal and logs warning", %{tmp: tmp} do
    File.write!(tmp, "not json {{{{")
    stop_supervised!(GainAccumulatorStore)
    start_supervised!(GainAccumulatorStore)
    assert GainAccumulatorStore.principal() == nil
  end
end
