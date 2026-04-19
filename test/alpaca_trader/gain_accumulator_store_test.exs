defmodule AlpacaTrader.GainAccumulatorStoreTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.GainAccumulatorStore

  setup do
    tmp = System.tmp_dir!() <> "/gain_acc_test_#{:erlang.unique_integer([:positive])}.json"
    Application.put_env(:alpaca_trader, :gain_accumulator_path, tmp)
    Application.put_env(:alpaca_trader, :order_notional_pct, 0.001)
    Application.put_env(:alpaca_trader, :trade_fee_rate, 0.003)
    GainAccumulatorStore.reset()

    on_exit(fn ->
      try do
        File.rm(tmp)
      rescue
        _ -> :ok
      end
    end)

    %{tmp: tmp}
  end

  test "first call snapshots principal and allows entry", %{tmp: tmp} do
    assert GainAccumulatorStore.allow_entry?(100.0)
    assert Decimal.equal?(GainAccumulatorStore.principal(), Decimal.new("100.0"))
    assert File.exists?(tmp)
    assert {:ok, %{"principal" => principal_str, "date" => _}} = Jason.decode(File.read!(tmp))
    assert Decimal.equal?(Decimal.new(principal_str), Decimal.new("100.0"))
  end

  test "allows entry when loss is within fee tolerance" do
    # principal=100, equity=99.9995 → gain=-0.0005
    # fee_tolerance = max(99.9995 * 0.001 * 0.003, 99.9995 * 0.001 * 0.01)
    #               = max(~0.0003, ~0.001) = ~0.001
    # -0.0005 >= -0.001 → allowed
    GainAccumulatorStore.allow_entry?(100.0)
    assert GainAccumulatorStore.allow_entry?(99.9995)
  end

  test "blocks entry when loss exceeds fee tolerance" do
    # principal=100, equity=99.98 → gain=-0.02
    # fee_tolerance = max(99.98 * 0.001 * 0.003, 99.98 * 0.001 * 0.01)
    #               = max(0.0003, 0.001) = 0.001
    # -0.02 >= -0.001 → false → blocked
    GainAccumulatorStore.allow_entry?(100.0)
    refute GainAccumulatorStore.allow_entry?(99.98)
  end

  test "allows entry when equity is above principal" do
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
end
