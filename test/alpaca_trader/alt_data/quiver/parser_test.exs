defmodule AlpacaTrader.AltData.Quiver.ParserTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.AltData.Quiver.Parser
  alias AlpacaTrader.AltData.Signal

  defp load_fixture(name) do
    Path.join([__DIR__, "..", "..", "..", "support", "fixtures", "quiver", "#{name}.json"])
    |> File.read!()
    |> Jason.decode!()
  end

  describe "parse_congress/3" do
    setup do
      now = ~U[2026-04-30 12:00:00Z]
      {:ok, rows: load_fixture("congress"), now: now}
    end

    test "groups by ticker within lookback window and emits one signal per group", %{rows: rows, now: now} do
      signals = Parser.parse_congress(rows, now, 14)

      tickers = Enum.map(signals, & hd(&1.affected_symbols)) |> Enum.sort()
      assert tickers == ["BA", "NVDA"]
      # AAPL filing is older than 14d lookback (~60d) and must be filtered out.
      refute Enum.any?(signals, fn s -> "AAPL" in s.affected_symbols end)
    end

    test "marks bullish when net Purchases > Sales", %{rows: rows, now: now} do
      [nvda] = Enum.filter(Parser.parse_congress(rows, now, 14), &("NVDA" in &1.affected_symbols))
      assert nvda.direction == :bullish
      assert nvda.signal_type == :congress_trade
      assert nvda.provider == :quiver_congress
      # Net = +3 (3 buys, 0 sells); strength = min(1.0, 3/5) = 0.6
      assert_in_delta nvda.strength, 0.6, 0.001
    end

    test "marks bearish when net Sales > Purchases", %{rows: rows, now: now} do
      [ba] = Enum.filter(Parser.parse_congress(rows, now, 14), &("BA" in &1.affected_symbols))
      assert ba.direction == :bearish
      assert_in_delta ba.strength, 0.2, 0.001
    end

    test "sets fetched_at = now and expires_at = now + lookback days", %{rows: rows, now: now} do
      [s | _] = Parser.parse_congress(rows, now, 14)
      assert DateTime.compare(s.fetched_at, now) == :eq
      assert DateTime.compare(s.expires_at, DateTime.add(now, 14 * 24 * 3600, :second)) == :eq
    end

    test "raw payload contains net_count and filings list", %{rows: rows, now: now} do
      [nvda] = Enum.filter(Parser.parse_congress(rows, now, 14), &("NVDA" in &1.affected_symbols))
      assert nvda.raw[:net_count] == 3
      assert is_list(nvda.raw[:filings])
      assert length(nvda.raw[:filings]) == 3
    end

    test "returns [] when input is empty or all rows are stale", %{now: now} do
      assert Parser.parse_congress([], now, 14) == []
      assert Parser.parse_congress([%{"Ticker" => "X", "Transaction" => "Purchase", "TransactionDate" => "2020-01-01"}], now, 14) == []
    end

    test "skips rows with missing ticker or unparseable date", %{now: now} do
      junk = [
        %{"Ticker" => nil, "Transaction" => "Purchase", "TransactionDate" => "2026-04-22"},
        %{"Ticker" => "X", "Transaction" => "Purchase", "TransactionDate" => "not-a-date"}
      ]
      assert Parser.parse_congress(junk, now, 14) == []
    end
  end
end
