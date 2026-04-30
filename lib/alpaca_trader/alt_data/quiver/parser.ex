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
    |> Enum.flat_map(fn {ticker, group} ->
      [build_congress_signal(ticker, group, now, lookback_days)]
    end)
  end

  defp normalize_congress_row(
         %{"Ticker" => t, "Transaction" => txn, "TransactionDate" => date_str} = row
       )
       when is_binary(t) and t != "" and is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, d} ->
        [
          %{
            ticker: String.upcase(t),
            txn_kind: classify_congress_txn(txn),
            txn_dt: DateTime.new!(d, ~T[00:00:00], "Etc/UTC"),
            range: row["Range"],
            rep: row["Representative"],
            house: row["House"]
          }
        ]

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

  @doc "Insider Form-4 filings — `/beta/live/insiders`."
  @spec parse_insider(list(map()), DateTime.t(), pos_integer()) :: [Signal.t()]
  def parse_insider(rows, now, lookback_days) when is_list(rows) do
    cutoff = DateTime.add(now, -lookback_days * 24 * 3600, :second)

    rows
    |> Enum.flat_map(&normalize_insider_row/1)
    |> Enum.filter(fn r -> DateTime.compare(r.txn_dt, cutoff) != :lt end)
    |> Enum.group_by(& &1.ticker)
    |> Enum.map(fn {ticker, group} -> build_insider_signal(ticker, group, now, lookback_days) end)
  end

  defp normalize_insider_row(
         %{
           "Ticker" => t,
           "Code" => code,
           "Shares" => sh,
           "PricePerShare" => pps,
           "Date" => date_str
         } = row
       )
       when is_binary(t) and t != "" and code in ["P", "S"] and is_binary(date_str) do
    with {:ok, d} <- Date.from_iso8601(date_str),
         {shares, _} <- Float.parse(to_string(sh)),
         {price, _} <- Float.parse(to_string(pps)) do
      [
        %{
          ticker: String.upcase(t),
          code: code,
          dollars: shares * price * if(code == "P", do: 1.0, else: -1.0),
          insider: row["Name"],
          txn_dt: DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
        }
      ]
    else
      _ -> []
    end
  end

  defp normalize_insider_row(_), do: []

  defp build_insider_signal(ticker, group, now, lookback_days) do
    net_dollars = group |> Enum.map(& &1.dollars) |> Enum.sum()

    direction =
      cond do
        net_dollars > 0 -> :bullish
        net_dollars < 0 -> :bearish
        true -> :neutral
      end

    {cluster?, signal_type} =
      case classify_insider_cluster(group, direction) do
        :cluster_buy -> {true, :insider_buy_cluster}
        :cluster_sell -> {true, :insider_sell_cluster}
        :single -> {false, :insider_trade}
      end

    threshold = if cluster?, do: 500_000.0, else: 1_000_000.0
    strength = min(1.0, abs(net_dollars) / threshold)

    %Signal{
      provider: :quiver_insider,
      signal_type: signal_type,
      direction: direction,
      strength: strength,
      affected_symbols: [ticker],
      reason:
        "Insider net=$#{trunc(net_dollars)} over #{lookback_days}d (#{length(group)} filings)",
      fetched_at: now,
      expires_at: DateTime.add(now, lookback_days * 24 * 3600, :second),
      raw: %{net_dollars: net_dollars, filings: length(group), cluster: cluster?}
    }
  end

  defp classify_insider_cluster(group, direction) do
    same_dir =
      Enum.filter(group, fn r ->
        (direction == :bullish and r.code == "P") or (direction == :bearish and r.code == "S")
      end)

    distinct_insiders =
      same_dir
      |> Enum.map(& &1.insider)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> length()

    cond do
      distinct_insiders >= 2 and direction == :bullish -> :cluster_buy
      distinct_insiders >= 2 and direction == :bearish -> :cluster_sell
      true -> :single
    end
  end
end
