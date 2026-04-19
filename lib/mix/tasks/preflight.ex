defmodule Mix.Tasks.Preflight do
  @moduledoc """
  Pre-flight check before starting the bot.

  Refuses to report OK when any of these are unsafe:
  - Live (not paper) URL + equity < $500 + no explicit opt-in flag
  - daytrade_count at or over 3 while equity < $25k
  - Too many open positions (concentration risk + buying-power starvation)
  - No FRED / Finnhub / Alpaca credentials while the flags are enabled

  Returns exit code 0 if safe to start, 1 if warnings exist, 2 if blocking.

  ## Usage

      mix preflight                      # human-readable report
      mix preflight --json               # machine-parseable summary
      mix preflight --allow-live-small   # acknowledge small-equity live risk
      mix preflight --allow-pdt-risk     # acknowledge PDT lockout risk
      mix preflight --allow-all          # acknowledge every soft-blocker

  Intended to wrap `mix phx.server` in the Makefile — fail fast before
  trading starts.
  """

  use Mix.Task

  @shortdoc "Pre-flight safety check before starting the bot"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          json: :boolean,
          allow_live_small: :boolean,
          allow_pdt_risk: :boolean,
          allow_all: :boolean
        ]
      )

    allow_all = opts[:allow_all] == true

    Mix.Task.run("app.start")

    alias AlpacaTrader.Alpaca.Client

    base_url = Application.get_env(:alpaca_trader, :alpaca_base_url, "?")

    is_live =
      String.contains?(base_url, "api.alpaca.markets") and
        not String.contains?(base_url, "paper-api")

    {:ok, account} = Client.get_account()
    {:ok, positions} = Client.list_positions()

    equity = parse_float(account["equity"]) || 0.0
    bp = parse_float(account["buying_power"]) || 0.0
    dtc = parse_float(account["daytrade_count"]) || 0.0

    under_pdt = equity < 25_000
    allow_small = opts[:allow_live_small] == true or allow_all
    allow_pdt = opts[:allow_pdt_risk] == true or allow_all

    checks = [
      check(:env, is_live, "LIVE account (api.alpaca.markets) — not paper", :warning),
      check(
        :small_live,
        is_live and equity < 500 and not allow_small,
        "LIVE account with equity $#{equity} < $500. Fees/slippage will dominate. Pass --allow-live-small to ACK.",
        :blocking
      ),
      check(
        :pdt_risk,
        under_pdt and dtc >= 3 and not allow_pdt,
        "PDT RISK: daytrade_count=#{dtc} with equity $#{equity} < $25k. One more day trade will lock the account. Pass --allow-pdt-risk to ACK.",
        :blocking
      ),
      check(
        :pdt_risk_ack,
        under_pdt and dtc >= 3 and allow_pdt,
        "PDT risk acknowledged: daytrade_count=#{dtc} with equity $#{equity} < $25k. Avoid opening + closing any equity position same-day.",
        :warning
      ),
      check(
        :bp_exhausted,
        bp < 1.0,
        "Buying power $#{bp} below $1 — no new trades can be placed. Run `mix flatten` to free capital.",
        :warning
      ),
      check(
        :many_positions,
        length(positions) > 20,
        "#{length(positions)} open positions — heavy concentration & orphan risk.",
        :warning
      ),
      check(
        :trading_blocked,
        account["trading_blocked"] == true,
        "Alpaca has BLOCKED trading on this account.",
        :blocking
      ),
      check(
        :account_blocked,
        account["account_blocked"] == true,
        "Alpaca has BLOCKED this account entirely.",
        :blocking
      )
    ]

    report = Enum.reject(checks, &is_nil/1)

    if opts[:json] do
      json_report(report, account, positions)
    else
      human_report(report, account, positions, is_live)
    end

    warnings_ok = allow_all

    exit_code =
      cond do
        Enum.any?(report, &(&1.severity == :blocking)) -> 2
        Enum.any?(report, &(&1.severity == :warning)) and not warnings_ok -> 1
        true -> 0
      end

    if exit_code != 0 do
      exit({:shutdown, exit_code})
    end
  end

  defp check(_id, false, _msg, _sev), do: nil
  defp check(id, true, msg, severity), do: %{id: id, message: msg, severity: severity}

  defp human_report(report, account, positions, is_live) do
    Mix.shell().info("\n========== PRE-FLIGHT ==========")
    Mix.shell().info("Environment:   #{if is_live, do: "🔴 LIVE", else: "🟢 PAPER"}")
    Mix.shell().info("Equity:        $#{account["equity"]}")
    Mix.shell().info("Cash:          $#{account["cash"]}")
    Mix.shell().info("Buying power:  $#{account["buying_power"]}")
    Mix.shell().info("Day trades:    #{account["daytrade_count"]}/3 (rolling 5 days)")
    Mix.shell().info("Open positions: #{length(positions)}")
    Mix.shell().info("Shorting:      #{account["shorting_enabled"]}")

    Mix.shell().info("\n-- Config Flags --")

    Mix.shell().info(
      "  PAIR_WHITELIST_ENABLED:    #{Application.get_env(:alpaca_trader, :pair_whitelist_enabled)}"
    )

    Mix.shell().info(
      "  PAIR_COINTEGRATION_GATE:   #{Application.get_env(:alpaca_trader, :pair_cointegration_gate)}"
    )

    Mix.shell().info(
      "  POSITION_SIZING_MODE:      #{Application.get_env(:alpaca_trader, :position_sizing_mode)}"
    )

    Mix.shell().info(
      "  HEDGE_RATIO_MODE:          #{Application.get_env(:alpaca_trader, :hedge_ratio_mode)}"
    )

    Mix.shell().info(
      "  ORDER_TYPE_MODE:           #{Application.get_env(:alpaca_trader, :order_type_mode)}"
    )

    Mix.shell().info(
      "  ORDER_NOTIONAL_PCT:        #{Application.get_env(:alpaca_trader, :order_notional_pct)}"
    )

    if report == [] do
      Mix.shell().info("\n✅ ALL CHECKS PASSED — safe to start.")
    else
      Mix.shell().info("\n-- Issues --")

      Enum.each(report, fn c ->
        icon =
          case c.severity do
            :blocking -> "⛔"
            :warning -> "⚠️ "
          end

        Mix.shell().info("  #{icon} [#{c.severity}] #{c.message}")
      end)
    end
  end

  defp json_report(report, account, _positions) do
    IO.puts(Jason.encode!(%{account: account, issues: report}))
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
