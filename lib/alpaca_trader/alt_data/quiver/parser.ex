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

  defp normalize_congress_row(%{"Ticker" => t, "Transaction" => txn} = row)
       when is_binary(t) and t != "" do
    date_str = row["Traded"] || row["TransactionDate"]

    if is_binary(date_str) do
      case Date.from_iso8601(date_str) do
        {:ok, d} ->
          [
            %{
              ticker: String.upcase(t),
              txn_kind: classify_congress_txn(txn),
              txn_dt: DateTime.new!(d, ~T[00:00:00], "Etc/UTC"),
              range: row["Trade_Size_USD"] || row["Range"],
              rep: row["Name"] || row["Representative"],
              house: row["Chamber"] || row["House"]
            }
          ]

        _ ->
          []
      end
    else
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

  defp normalize_insider_row(%{"Ticker" => t, "Shares" => sh, "PricePerShare" => pps} = row)
       when is_binary(t) and t != "" do
    code = row["TransactionCode"] || row["Code"]
    date_str = row["Date"]

    with true <- code in ["P", "S"],
         true <- is_binary(date_str),
         {:ok, d} <- parse_iso_date_prefix(date_str),
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

  defp parse_iso_date_prefix(s) when is_binary(s) do
    s |> String.slice(0, 10) |> Date.from_iso8601()
  end

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

  @doc "Federal contract awards — `/beta/live/govcontractsall`."
  @spec parse_govcontracts(list(map()), DateTime.t(), pos_integer()) :: [Signal.t()]
  def parse_govcontracts(rows, now, lookback_days) when is_list(rows) do
    cutoff = DateTime.add(now, -lookback_days * 24 * 3600, :second)

    rows
    |> Enum.flat_map(&normalize_contract_row/1)
    |> Enum.filter(fn r -> DateTime.compare(r.dt, cutoff) != :lt and r.amount > 0 end)
    |> Enum.group_by(& &1.ticker)
    |> Enum.map(fn {ticker, group} ->
      build_contract_signal(ticker, group, now, lookback_days)
    end)
  end

  defp normalize_contract_row(%{"Ticker" => t, "Amount" => amt, "Date" => date_str} = row)
       when is_binary(t) and t != "" and is_binary(date_str) do
    with {:ok, d} <- Date.from_iso8601(date_str),
         {amount, _} <- Float.parse(to_string(amt)) do
      [
        %{
          ticker: String.upcase(t),
          amount: amount,
          agency: row["Agency"],
          description: row["Description"],
          dt: DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
        }
      ]
    else
      _ -> []
    end
  end

  defp normalize_contract_row(_), do: []

  defp build_contract_signal(ticker, group, now, lookback_days) do
    total = group |> Enum.map(& &1.amount) |> Enum.sum() |> trunc()
    strength = min(1.0, total / 100_000_000)

    %Signal{
      provider: :quiver_govcontracts,
      signal_type: :gov_contract_award,
      direction: :bullish,
      strength: strength,
      affected_symbols: [ticker],
      reason: "$#{total} in federal contracts over #{lookback_days}d (#{length(group)} awards)",
      fetched_at: now,
      expires_at: DateTime.add(now, lookback_days * 24 * 3600, :second),
      raw: %{
        total_amount: total,
        award_count: length(group),
        agencies: group |> Enum.map(& &1.agency) |> Enum.uniq()
      }
    }
  end

  @doc "Lobbying disclosures — `/live/lobbying`. Latest disclosed quarter, with prior-year YoY delta."
  @spec parse_lobbying(list(map()), DateTime.t()) :: [Signal.t()]
  def parse_lobbying(rows, now) when is_list(rows) do
    rows
    |> Enum.flat_map(&normalize_lobbying_row/1)
    |> Enum.group_by(& &1.ticker)
    |> Enum.map(fn {ticker, group} -> build_lobbying_signal(ticker, group, now) end)
  end

  defp normalize_lobbying_row(%{"Ticker" => t, "Amount" => amt} = row)
       when is_binary(t) and t != "" do
    {yr, q} = extract_year_quarter(row)

    with true <- is_integer(yr) and is_integer(q),
         {amount, _} <- Float.parse(to_string(amt)) do
      [%{ticker: String.upcase(t), amount: amount, year: yr, quarter: q}]
    else
      _ -> []
    end
  end

  defp normalize_lobbying_row(_), do: []

  defp extract_year_quarter(%{"Year" => y, "Quarter" => q}) when is_integer(y) and is_integer(q),
    do: {y, q}

  defp extract_year_quarter(%{"Date" => date_str}) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, d} -> {d.year, div(d.month - 1, 3) + 1}
      _ -> {nil, nil}
    end
  end

  defp extract_year_quarter(_), do: {nil, nil}

  defp build_lobbying_signal(ticker, group, now) do
    {latest_year, latest_quarter} =
      group
      |> Enum.map(&{&1.year, &1.quarter})
      |> Enum.max(fn a, b -> a >= b end, fn -> {0, 0} end)

    current =
      group
      |> Enum.filter(&(&1.year == latest_year and &1.quarter == latest_quarter))
      |> Enum.map(& &1.amount)
      |> Enum.sum()

    prior =
      group
      |> Enum.filter(&(&1.year == latest_year - 1 and &1.quarter == latest_quarter))
      |> Enum.map(& &1.amount)
      |> Enum.sum()

    strength =
      if prior > 0 do
        min(1.0, abs(current - prior) / prior)
      else
        0.0
      end

    %Signal{
      provider: :quiver_lobbying,
      signal_type: :lobbying_spike,
      direction: :neutral,
      strength: strength,
      affected_symbols: [ticker],
      reason:
        "Lobbying $#{trunc(current)} (Q#{latest_quarter} #{latest_year}) vs $#{trunc(prior)} prior year",
      fetched_at: now,
      expires_at: DateTime.add(now, 90 * 24 * 3600, :second),
      raw: %{current: current, prior_year: prior, year: latest_year, quarter: latest_quarter}
    }
  end

  @doc "WallStreetBets sentiment — `/live/wallstreetbets`."
  @spec parse_wsb(list(map()), DateTime.t()) :: [Signal.t()]
  def parse_wsb(rows, now) when is_list(rows) do
    rows
    |> Enum.flat_map(&normalize_wsb_row/1)
    |> Enum.map(&build_wsb_signal(&1, now))
  end

  defp normalize_wsb_row(%{
         "Ticker" => t,
         "Mentions" => m,
         "PreviousMentions" => prev,
         "Sentiment" => s
       })
       when is_binary(t) and t != "" do
    with {mentions, _} <- safe_to_float(m),
         {prev_mentions, _} <- safe_to_float(prev),
         {sentiment, _} <- safe_to_float(s) do
      [%{ticker: String.upcase(t), mentions: mentions, prev: prev_mentions, sentiment: sentiment}]
    else
      _ -> []
    end
  end

  defp normalize_wsb_row(_), do: []

  defp safe_to_float(n) when is_number(n), do: {n / 1, ""}
  defp safe_to_float(s) when is_binary(s), do: Float.parse(s)
  defp safe_to_float(_), do: :error

  defp build_wsb_signal(row, now) do
    rising? = row.mentions > row.prev

    direction =
      cond do
        row.sentiment > 0.6 and rising? -> :bullish
        row.sentiment < 0.4 and rising? -> :bearish
        true -> :neutral
      end

    strength = min(1.0, row.mentions / 500.0)

    %Signal{
      provider: :quiver_wsb,
      signal_type: :wsb_sentiment,
      direction: direction,
      strength: strength,
      affected_symbols: [row.ticker],
      reason:
        "WSB sentiment=#{row.sentiment} mentions=#{trunc(row.mentions)} (prev=#{trunc(row.prev)})",
      fetched_at: now,
      expires_at: DateTime.add(now, 24 * 3600, :second),
      raw: %{mentions: row.mentions, prev_mentions: row.prev, sentiment: row.sentiment}
    }
  end
end
