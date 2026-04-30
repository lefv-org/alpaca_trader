defmodule AlpacaTrader.AltData.Quiver.ParserTest do
  use ExUnit.Case, async: true
  alias AlpacaTrader.AltData.Quiver.Parser

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

    test "groups by ticker within lookback window and emits one signal per group", %{
      rows: rows,
      now: now
    } do
      signals = Parser.parse_congress(rows, now, 14)

      tickers = Enum.map(signals, &hd(&1.affected_symbols)) |> Enum.sort()
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

      assert Parser.parse_congress(
               [
                 %{
                   "Ticker" => "X",
                   "Transaction" => "Purchase",
                   "TransactionDate" => "2020-01-01"
                 }
               ],
               now,
               14
             ) == []
    end

    test "skips rows with missing ticker or unparseable date", %{now: now} do
      junk = [
        %{"Ticker" => nil, "Transaction" => "Purchase", "TransactionDate" => "2026-04-22"},
        %{"Ticker" => "X", "Transaction" => "Purchase", "TransactionDate" => "not-a-date"},
        %{"Ticker" => "Z", "Transaction" => "Purchase", "TransactionDate" => nil}
      ]

      assert Parser.parse_congress(junk, now, 14) == []
    end
  end

  describe "parse_insider/3" do
    setup do
      now = ~U[2026-04-30 12:00:00Z]
      {:ok, rows: load_fixture("insider"), now: now}
    end

    test "skips rows outside lookback window", %{rows: rows, now: now} do
      signals = Parser.parse_insider(rows, now, 30)
      tickers = Enum.flat_map(signals, & &1.affected_symbols) |> Enum.sort()
      assert tickers == ["AAPL", "BA"]
    end

    test "tags cluster when 2+ insiders buy same ticker", %{rows: rows, now: now} do
      [aapl] = Enum.filter(Parser.parse_insider(rows, now, 30), &("AAPL" in &1.affected_symbols))
      assert aapl.direction == :bullish
      assert aapl.signal_type == :insider_buy_cluster
      # Net = 5000*180 + 3000*180 = 1_440_000; cluster threshold 500_000
      # strength = min(1.0, 1_440_000 / 500_000) = 1.0
      assert_in_delta aapl.strength, 1.0, 0.001
    end

    test "single insider sale uses :insider_trade and 1M threshold", %{now: now} do
      rows = [
        %{
          "Ticker" => "X",
          "Name" => "P1",
          "Code" => "S",
          "Shares" => "1000",
          "PricePerShare" => "300.00",
          "Date" => "2026-04-25"
        }
      ]

      [s] = Parser.parse_insider(rows, now, 30)
      assert s.direction == :bearish
      assert s.signal_type == :insider_trade
      # Net = -300_000; threshold 1_000_000; strength = 0.3
      assert_in_delta s.strength, 0.3, 0.001
    end

    test "skips rows with non-P/S codes", %{now: now} do
      rows = [
        %{
          "Ticker" => "X",
          "Name" => "P1",
          "Code" => "G",
          "Shares" => "100",
          "PricePerShare" => "10",
          "Date" => "2026-04-25"
        }
      ]

      assert Parser.parse_insider(rows, now, 30) == []
    end

    test "net_dollars == 0 emits :neutral with strength 0", %{now: now} do
      rows = [
        %{
          "Ticker" => "X",
          "Name" => "P1",
          "Code" => "P",
          "Shares" => "1000",
          "PricePerShare" => "100.00",
          "Date" => "2026-04-25"
        },
        %{
          "Ticker" => "X",
          "Name" => "P2",
          "Code" => "S",
          "Shares" => "1000",
          "PricePerShare" => "100.00",
          "Date" => "2026-04-25"
        }
      ]

      [s] = Parser.parse_insider(rows, now, 30)
      assert s.direction == :neutral
      assert_in_delta s.strength, 0.0, 0.001
    end

    test "skips rows with nil date", %{now: now} do
      rows = [
        %{
          "Ticker" => "X",
          "Name" => "P1",
          "Code" => "P",
          "Shares" => "1000",
          "PricePerShare" => "100.00",
          "Date" => nil
        }
      ]

      assert Parser.parse_insider(rows, now, 30) == []
    end
  end

  describe "parse_govcontracts/3" do
    setup do
      now = ~U[2026-04-30 12:00:00Z]
      {:ok, rows: load_fixture("govcontracts"), now: now}
    end

    test "filters stale rows and cancellations", %{rows: rows, now: now} do
      signals = Parser.parse_govcontracts(rows, now, 30)
      tickers = Enum.flat_map(signals, & &1.affected_symbols) |> Enum.sort()
      assert tickers == ["BA", "LMT"]
    end

    test "always bullish on award totals", %{rows: rows, now: now} do
      [lmt] =
        Enum.filter(Parser.parse_govcontracts(rows, now, 30), &("LMT" in &1.affected_symbols))

      assert lmt.direction == :bullish
      assert lmt.signal_type == :gov_contract_award
      # 45M + 60M = 105M; cap at 100M; strength clipped to 1.0
      assert_in_delta lmt.strength, 1.0, 0.001
    end

    test "BA cancellation is excluded; only the 20M award counts", %{rows: rows, now: now} do
      [ba] = Enum.filter(Parser.parse_govcontracts(rows, now, 30), &("BA" in &1.affected_symbols))
      assert ba.raw[:total_amount] == 20_000_000
      assert_in_delta ba.strength, 0.2, 0.001
    end

    test "skips rows with nil date", %{now: now} do
      rows = [
        %{
          "Ticker" => "X",
          "Amount" => "1000",
          "Description" => "X",
          "Date" => nil,
          "Agency" => "DOD"
        }
      ]

      assert Parser.parse_govcontracts(rows, now, 30) == []
    end
  end

  describe "parse_lobbying/2" do
    setup do
      now = ~U[2026-04-30 12:00:00Z]
      {:ok, rows: load_fixture("lobbying"), now: now}
    end

    test "computes YoY delta strength when prior year exists", %{rows: rows, now: now} do
      [googl] = Enum.filter(Parser.parse_lobbying(rows, now), &("GOOGL" in &1.affected_symbols))
      assert googl.direction == :neutral
      assert googl.signal_type == :lobbying_spike
      # |3.5M - 2M| / max(1, 2M) = 0.75
      assert_in_delta googl.strength, 0.75, 0.001
    end

    test "strength = 0.0 when prior year missing", %{rows: rows, now: now} do
      [newco] = Enum.filter(Parser.parse_lobbying(rows, now), &("NEWCO" in &1.affected_symbols))
      assert newco.strength == 0.0
    end

    test "expires_at = now + 90d", %{rows: rows, now: now} do
      [s | _] = Parser.parse_lobbying(rows, now)
      assert DateTime.compare(s.expires_at, DateTime.add(now, 90 * 24 * 3600, :second)) == :eq
    end
  end

  describe "parse_wsb/2" do
    setup do
      now = ~U[2026-04-30 12:00:00Z]
      {:ok, rows: load_fixture("wsb"), now: now}
    end

    test "bullish when sentiment > 0.6 AND mentions rising", %{rows: rows, now: now} do
      [gme] = Enum.filter(Parser.parse_wsb(rows, now), &("GME" in &1.affected_symbols))
      assert gme.direction == :bullish
      assert gme.signal_type == :wsb_sentiment
      # 650 / 500 capped at 1.0
      assert_in_delta gme.strength, 1.0, 0.001
    end

    test "neutral when sentiment in middle band even with rising mentions", %{
      rows: rows,
      now: now
    } do
      [nvda] = Enum.filter(Parser.parse_wsb(rows, now), &("NVDA" in &1.affected_symbols))
      assert nvda.direction == :neutral
    end

    test "bearish requires sentiment < 0.4 AND mentions rising", %{rows: rows, now: now} do
      # AMC: sentiment 0.30 but mentions DROPPED -> :neutral
      [amc] = Enum.filter(Parser.parse_wsb(rows, now), &("AMC" in &1.affected_symbols))
      assert amc.direction == :neutral

      # TSLA: sentiment 0.20 AND mentions dropped -> :neutral
      [tsla] = Enum.filter(Parser.parse_wsb(rows, now), &("TSLA" in &1.affected_symbols))
      assert tsla.direction == :neutral

      # synthetic bearish: low sentiment + rising mentions
      bear_row = [
        %{
          "Ticker" => "X",
          "Mentions" => 300,
          "PreviousMentions" => 100,
          "Sentiment" => 0.15,
          "Date" => "2026-04-30"
        }
      ]

      [x] = Parser.parse_wsb(bear_row, now)
      assert x.direction == :bearish
    end

    test "expires_at = now + 24h", %{rows: rows, now: now} do
      [s | _] = Parser.parse_wsb(rows, now)
      assert DateTime.compare(s.expires_at, DateTime.add(now, 24 * 3600, :second)) == :eq
    end
  end
end
