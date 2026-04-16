defmodule AlpacaTrader.GainAccumulatorStore do
  @moduledoc """
  Daily loss gate anchored to the calendar day, with Decimal-precision math.

  At the start of each trading day, snapshots the account equity as the day's
  "principal." Blocks new entries if equity has since dropped by more than one
  round-trip's fees. The anchor persists across restarts so an intraday crash
  does not reset the drawdown floor.

  Loss tolerance = equity * ORDER_NOTIONAL_PCT * TRADE_FEE_RATE (floored at 1%
  of one trade's notional so tiny accounts don't lock themselves out on a
  single crypto spread).

  All monetary math uses `Decimal` to avoid the float drift that matters at
  thresholds near zero. Callers may pass floats, numbers, or Decimals —
  conversion happens at the boundary.
  """

  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Returns true unless equity has dropped below today's principal by more than
  one trade's fees.
  """
  def allow_entry?(nil), do: false

  def allow_entry?(equity) do
    case to_decimal(equity) do
      nil -> false
      d -> GenServer.call(__MODULE__, {:allow_entry, d})
    end
  end

  @doc "Accumulated gain capital: max(0, equity - today's principal). Returns 0.0 before snapshot."
  def trading_capital(equity) do
    case {to_decimal(equity), principal()} do
      {nil, _} -> 0.0
      {_, nil} -> 0.0
      {e, p} ->
        e
        |> Decimal.sub(p)
        |> Decimal.max(Decimal.new(0))
        |> Decimal.to_float()
    end
  end

  @doc "Today's principal as a Decimal. Nil if not yet snapshotted."
  def principal do
    GenServer.call(__MODULE__, :principal)
  end

  @doc "Clears state and deletes the JSON file. For testing and manual reset."
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # ── GenServer callbacks ─────────────────────────────────────

  @impl true
  def init(_) do
    {:ok, load_state()}
  end

  @impl true
  def handle_call({:allow_entry, equity}, _from, state) do
    today = Date.utc_today()

    if state.date != today do
      new_state = %{date: today, principal: equity}
      persist_session(new_state, equity)
      Logger.info("[GainAccumulator] 📸 #{today} principal=$#{fmt(equity)} established — trading enabled")
      {:reply, true, new_state}
    else
      check_gain(state, equity)
    end
  end

  def handle_call(:principal, _from, state) do
    {:reply, state.principal, state}
  end

  def handle_call(:reset, _from, _state) do
    path = file_path()
    if File.exists?(path), do: File.rm(path)
    Logger.info("[GainAccumulator] reset — principal cleared")
    {:reply, :ok, %{date: nil, principal: nil}}
  end

  # ── Internals ───────────────────────────────────────────────

  defp check_gain(%{principal: principal} = state, equity) do
    notional_pct = to_decimal(Application.get_env(:alpaca_trader, :order_notional_pct, 0.001))
    fee_rate = to_decimal(Application.get_env(:alpaca_trader, :trade_fee_rate, 0.003))
    one_pct = Decimal.from_float(0.01)

    base = Decimal.mult(equity, notional_pct)
    min_tolerance = Decimal.mult(base, one_pct)
    fee_tolerance = Decimal.max(Decimal.mult(base, fee_rate), min_tolerance)

    gain = Decimal.sub(equity, principal)
    neg_tolerance = Decimal.negate(fee_tolerance)

    persist_session(state, equity)

    if Decimal.compare(gain, neg_tolerance) != :lt do
      Logger.info("[GainAccumulator] ✅ gain=$#{fmt(gain)} (tolerance=$#{fmt(fee_tolerance, 4)}) — entry allowed")
      {:reply, true, state}
    else
      Logger.debug("[GainAccumulator] 🔒 gain=$#{fmt(gain)} exceeds loss tolerance=$#{fmt(fee_tolerance, 4)} — entry blocked")
      {:reply, false, state}
    end
  end

  # ── Decimal boundary helpers ────────────────────────────────

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, ""} -> d
      _ -> nil
    end
  end

  defp fmt(d, places \\ 2)
  defp fmt(%Decimal{} = d, places), do: d |> Decimal.round(places) |> Decimal.to_string(:normal)
  defp fmt(n, places) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: places)

  # ── Persistence ─────────────────────────────────────────────

  defp file_path do
    Application.get_env(:alpaca_trader, :gain_accumulator_path, "priv/runtime/gain_accumulator.json")
  end

  defp load_state do
    today = Date.utc_today()

    case File.read(file_path()) do
      {:ok, content} ->
        with {:ok, %{"principal" => principal, "date" => date_str}} <- Jason.decode(content),
             {:ok, ^today} <- Date.from_iso8601(date_str),
             p when not is_nil(p) <- to_decimal(principal) do
          Logger.info("[GainAccumulator] resumed today's principal=$#{fmt(p)}")
          %{date: today, principal: p}
        else
          {:ok, other_date} when is_struct(other_date, Date) ->
            Logger.info("[GainAccumulator] stale principal from #{other_date} — will snapshot fresh on next tick")
            %{date: nil, principal: nil}

          _ ->
            %{date: nil, principal: nil}
        end

      {:error, :enoent} ->
        %{date: nil, principal: nil}

      {:error, reason} ->
        Logger.warning("[GainAccumulator] failed to load state: #{inspect(reason)}")
        %{date: nil, principal: nil}
    end
  end

  defp persist_session(%{date: date, principal: principal}, equity) do
    gain = Decimal.sub(equity, principal) |> Decimal.round(2)

    payload =
      Jason.encode!(%{
        date: Date.to_iso8601(date),
        principal: Decimal.to_string(principal, :normal),
        equity: Decimal.to_string(equity, :normal),
        gain: Decimal.to_string(gain, :normal),
        account_env: account_env(),
        snapshot_time: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    final = file_path()
    tmp = final <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(final)),
         :ok <- File.write(tmp, payload),
         :ok <- File.rename(tmp, final) do
      :ok
    else
      {:error, reason} ->
        Logger.error("[GainAccumulator] failed to persist session: #{inspect(reason)}")
    end
  end

  defp account_env do
    Application.get_env(:alpaca_trader, :alpaca_base_url, "unknown")
  end
end
