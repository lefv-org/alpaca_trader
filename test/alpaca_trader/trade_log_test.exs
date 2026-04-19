defmodule AlpacaTrader.TradeLogTest do
  # Sync — we mutate the singleton TradeLog's backing file.
  use ExUnit.Case, async: false

  alias AlpacaTrader.TradeLog

  setup do
    # Save the original file contents (if any) so the rest of the suite
    # still sees its history after we're done.
    path = TradeLog.path()
    original = File.read(path)

    # Start with an empty log file for each test.
    File.write!(path, "")

    on_exit(fn ->
      case original do
        {:ok, content} -> File.write!(path, content)
        {:error, _} -> File.rm_rf(path)
      end
    end)

    :ok
  end

  describe "performance_stats/0" do
    test "returns stats shape when >= 10 trades with mixed outcomes" do
      trades =
        Enum.map(1..8, fn _ -> %{pnl_pct: 0.02} end) ++
          Enum.map(1..4, fn _ -> %{pnl_pct: -0.01} end)

      Enum.each(trades, &TradeLog.record/1)
      # Flush casts via a synchronous call
      _ = TradeLog.read_all()

      stats = TradeLog.performance_stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :win_rate)
      assert Map.has_key?(stats, :avg_win_pct)
      assert Map.has_key?(stats, :avg_loss_pct)
      assert_in_delta stats.win_rate, 8 / 12, 1.0e-9
      assert_in_delta stats.avg_win_pct, 0.02, 1.0e-9
      assert_in_delta stats.avg_loss_pct, 0.01, 1.0e-9
    end

    test "returns empty map when fewer than 10 trades" do
      Enum.each(1..5, fn _ -> TradeLog.record(%{pnl_pct: 0.02}) end)
      _ = TradeLog.read_all()
      assert TradeLog.performance_stats() == %{}
    end

    test "returns empty map when all trades are wins (no loss sample)" do
      Enum.each(1..12, fn _ -> TradeLog.record(%{pnl_pct: 0.02}) end)
      _ = TradeLog.read_all()
      assert TradeLog.performance_stats() == %{}
    end
  end
end
