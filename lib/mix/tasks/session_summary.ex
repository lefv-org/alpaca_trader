defmodule Mix.Tasks.SessionSummary do
  @moduledoc """
  Print session P&L against live Alpaca equity.

  Reads today's principal from `priv/runtime/gain_accumulator.json` and
  fetches fresh equity from Alpaca. The JSON file only gets a new equity
  snapshot when the bot evaluates an entry, so reading it directly shows
  stale values whenever preflight (or any other gate) kept the bot idle.
  This task always queries Alpaca, so the summary reflects reality.

  ## Usage

      mix session_summary
  """

  use Mix.Task

  @shortdoc "Print session P&L using live Alpaca equity"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    alias AlpacaTrader.Alpaca.Client

    gain_file = Application.get_env(:alpaca_trader, :gain_accumulator_path, "priv/runtime/gain_accumulator.json")
    snapshot = read_snapshot(gain_file)

    case Client.get_account() do
      {:ok, account} ->
        live_equity = parse_float(account["equity"]) || 0.0
        principal = snapshot[:principal] || live_equity
        snapshot_age = snapshot[:age_human] || "no prior snapshot"

        gain = live_equity - principal
        sym = if gain >= 0, do: "📈", else: "📉"
        env = Application.get_env(:alpaca_trader, :alpaca_base_url, "unknown")

        IO.puts("")
        IO.puts("══════════════════════════════════════════════")
        IO.puts("  SESSION SUMMARY  (live Alpaca)")
        IO.puts("──────────────────────────────────────────────")
        IO.puts("  Principal:      $#{format(principal)}  (snapshot #{snapshot_age})")
        IO.puts("  Live Equity:    $#{format(live_equity)}")
        IO.puts("  Session P&L:    #{sym} $#{sign(gain)}#{format(abs(gain))}")
        IO.puts("  Account:        #{env}")
        IO.puts("══════════════════════════════════════════════")

      {:error, reason} ->
        IO.puts("  (could not fetch live Alpaca equity: #{inspect(reason)})")
        print_cached_only(snapshot)
    end
  end

  defp read_snapshot(path) do
    with {:ok, body} <- File.read(path),
         {:ok, map} <- Jason.decode(body) do
      principal = parse_float(map["principal"])
      age_human =
        case map["snapshot_time"] do
          t when is_binary(t) -> format_age(t)
          _ -> "unknown"
        end

      %{principal: principal, cached_equity: parse_float(map["equity"]), age_human: age_human, env: map["account_env"]}
    else
      _ -> %{}
    end
  end

  defp print_cached_only(%{principal: p, cached_equity: e} = s) when is_number(p) and is_number(e) do
    gain = e - p
    sym = if gain >= 0, do: "📈", else: "📉"
    IO.puts("  (showing cached values from last bot tick — age #{Map.get(s, :age_human, "?")})")
    IO.puts("  Principal:      $#{format(p)}")
    IO.puts("  Cached Equity:  $#{format(e)}")
    IO.puts("  Cached P&L:     #{sym} $#{sign(gain)}#{format(abs(gain))}")
  end

  defp print_cached_only(_), do: :ok

  defp format_age(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)
        cond do
          diff < 60 -> "#{diff}s ago"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          diff < 86_400 -> "#{div(diff, 3600)}h ago"
          true -> "#{div(diff, 86_400)}d ago"
        end

      _ -> "unknown"
    end
  end

  defp format(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)
  defp format(_), do: "?"

  defp sign(n) when is_number(n) and n >= 0, do: "+"
  defp sign(_), do: "-"

  defp parse_float(nil), do: nil
  defp parse_float(n) when is_number(n), do: n * 1.0
  defp parse_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end
end
