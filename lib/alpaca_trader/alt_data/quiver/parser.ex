defmodule AlpacaTrader.AltData.Quiver.Parser do
  @moduledoc """
  Pure parsers: raw QuiverQuant rows + `now` -> [AltData.Signal].
  One `parse_<feed>/N` per endpoint. No I/O, no application env reads.
  """

  alias AlpacaTrader.AltData.Signal

  @doc "Congress trades — `/bulk/congresstrading`."
  @spec parse_congress(list(map()), DateTime.t(), pos_integer()) :: [Signal.t()]
  def parse_congress(rows, now, lookback_days) when is_list(rows) do
    cutoff = DateTime.add(now, -lookback_days * 24 * 3600, :second)

    rows
    |> Enum.flat_map(&normalize_congress_row/1)
    |> Enum.filter(fn r -> DateTime.compare(r.txn_dt, cutoff) != :lt end)
    |> Enum.group_by(& &1.ticker)
    |> Enum.flat_map(fn {ticker, group} -> [build_congress_signal(ticker, group, now, lookback_days)] end)
  end

  defp normalize_congress_row(%{"Ticker" => t, "Transaction" => txn, "TransactionDate" => date_str} = row)
       when is_binary(t) and t != "" do
    case Date.from_iso8601(date_str) do
      {:ok, d} ->
        [%{
          ticker: String.upcase(t),
          txn_kind: classify_congress_txn(txn),
          txn_dt: DateTime.new!(d, ~T[00:00:00], "Etc/UTC"),
          range: row["Range"],
          rep: row["Representative"],
          house: row["House"]
        }]

      _ ->
        []
    end
  end

  defp normalize_congress_row(_), do: []

  defp classify_congress_txn("Purchase"), do: :buy
  defp classify_congress_txn("Sale" <> _), do: :sell
  defp classify_congress_txn(_), do: :other

  defp build_congress_signal(ticker, group, now, lookback_days) do
    buys = Enum.count(group, &(&1.txn_kind == :buy))
    sells = Enum.count(group, &(&1.txn_kind == :sell))
    net = buys - sells

    direction =
      cond do
        net > 0 -> :bullish
        net < 0 -> :bearish
        true -> :neutral
      end

    strength = min(1.0, abs(net) / 5.0)

    %Signal{
      provider: :quiver_congress,
      signal_type: :congress_trade,
      direction: direction,
      strength: strength,
      affected_symbols: [ticker],
      reason: "Congressional net=#{net} (#{buys} buys / #{sells} sells) over #{lookback_days}d",
      fetched_at: now,
      expires_at: DateTime.add(now, lookback_days * 24 * 3600, :second),
      raw: %{
        net_count: net,
        filings: Enum.map(group, &Map.take(&1, [:rep, :txn_kind, :txn_dt, :range, :house]))
      }
    }
  end
end
