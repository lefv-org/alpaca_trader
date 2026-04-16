defmodule Mix.Tasks.Flatten do
  @moduledoc """
  Safely close all open positions on Alpaca.

  Critical safeguard: under PDT rules (accounts < $25k, 3+ day trades in 5
  days), closing an equity position opened the SAME DAY triggers a day trade
  and may flag the account as a Pattern Day Trader. This task:

  1. Closes all crypto positions first (crypto doesn't trigger PDT)
  2. Closes equity positions NOT opened today
  3. Reports equity positions opened today that were skipped

  Use `--force-all` to close everything regardless (only if you've confirmed
  day_trade_count is safely below 3, or account equity >= $25k).

  ## Usage

      mix flatten                    # safe: crypto + non-same-day equity
      mix flatten --dry-run          # show what would be closed
      mix flatten --force-all        # close everything (dangerous under PDT)
      mix flatten --crypto-only      # crypto positions only
  """

  use Mix.Task

  @shortdoc "Close open positions safely (PDT-aware)"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [dry_run: :boolean, force_all: :boolean, crypto_only: :boolean]
      )

    Mix.Task.run("app.start")

    alias AlpacaTrader.Alpaca.Client

    {:ok, account} = Client.get_account()
    equity = parse_float(account["equity"]) || 0.0
    daytrade_count = parse_float(account["daytrade_count"]) || 0.0
    under_pdt_threshold = equity < 25_000

    {:ok, positions} = Client.list_positions()

    Mix.shell().info("Account: equity=$#{equity} daytrade_count=#{daytrade_count} under_pdt=#{under_pdt_threshold}")
    Mix.shell().info("Positions to evaluate: #{length(positions)}")

    {:ok, orders} = Client.list_orders(%{status: "filled", limit: 500, direction: "desc"})
    today = Date.utc_today()

    classified = Enum.map(positions, &classify(&1, orders, today))

    report(classified)

    if opts[:dry_run] do
      Mix.shell().info("\n--dry-run: no positions closed.")
    else
      to_close = select_closeable(classified, opts, under_pdt_threshold)

      if to_close == [] do
        Mix.shell().info("\nNothing to close (nothing qualifies under current safeguards).")
      else
        Mix.shell().info("\nClosing #{length(to_close)} positions...")
        close_all(to_close)
      end
    end
  end

  defp classify(pos, orders, today) do
    symbol = pos["symbol"]
    is_crypto = String.contains?(symbol, "/")
    # Same-day open = any filled buy/sell on this symbol dated today
    same_day? =
      Enum.any?(orders, fn o ->
        o["symbol"] == symbol and filled_today?(o["filled_at"], today)
      end)

    category =
      cond do
        is_crypto -> :crypto
        not same_day? -> :equity_prior_day
        true -> :equity_same_day
      end

    %{pos: pos, symbol: symbol, category: category, market_value: parse_float(pos["market_value"])}
  end

  defp select_closeable(classified, opts, under_pdt) do
    cond do
      opts[:crypto_only] ->
        Enum.filter(classified, &(&1.category == :crypto))

      opts[:force_all] ->
        classified

      # Default safe mode: crypto + prior-day equity only
      under_pdt ->
        Enum.filter(classified, &(&1.category in [:crypto, :equity_prior_day]))

      # Not under PDT threshold — safe to close all
      true ->
        classified
    end
  end

  defp report(classified) do
    by_cat = Enum.group_by(classified, & &1.category)
    crypto = by_cat[:crypto] || []
    prior = by_cat[:equity_prior_day] || []
    same_day = by_cat[:equity_same_day] || []

    Mix.shell().info("\n--- CLASSIFICATION ---")
    Mix.shell().info("  Crypto (safe to close):         #{length(crypto)}  total_value=$#{sum_mv(crypto)}")
    Mix.shell().info("  Equity prior-day (safe):        #{length(prior)}  total_value=$#{sum_mv(prior)}")
    Mix.shell().info("  Equity SAME-DAY (PDT risk):     #{length(same_day)}  total_value=$#{sum_mv(same_day)}")

    if length(same_day) > 0 do
      Mix.shell().info("\n  Same-day equity positions (will be SKIPPED unless --force-all):")

      Enum.each(same_day, fn c ->
        mv = (c.market_value || 0.0) * 1.0
        Mix.shell().info("    #{c.symbol} mv=$#{Float.round(mv, 2)}")
      end)
    end
  end

  defp close_all(classified) do
    alias AlpacaTrader.Alpaca.Client

    {ok, err} =
      Enum.reduce(classified, {0, 0}, fn c, {ok, err} ->
        case Client.close_position(c.symbol) do
          {:ok, _} ->
            Mix.shell().info("  ✓ closed #{c.symbol}")
            {ok + 1, err}

          {:error, reason} ->
            Mix.shell().info("  ✗ failed #{c.symbol}: #{inspect(reason) |> String.slice(0..80)}")
            {ok, err + 1}
        end
      end)

    Mix.shell().info("\nDone. Closed: #{ok}  Failed: #{err}")
  end

  defp sum_mv(list) do
    total =
      list
      |> Enum.map(&(&1.market_value || 0.0))
      |> Enum.map(&(&1 * 1.0))
      |> Enum.sum()

    Float.round(total * 1.0, 2)
  end

  defp filled_today?(nil, _), do: false

  defp filled_today?(ts, today) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> DateTime.to_date(dt) == today
      _ -> false
    end
  end

  defp parse_float(nil), do: nil

  defp parse_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float(n) when is_number(n), do: n * 1.0
end
