defmodule AlpacaTrader.GainAccumulatorStore do
  @moduledoc """
  Tracks original principal from first-boot equity snapshot.
  Gates new entries: blocks only when equity has dropped below principal by more
  than one trade's round-trip fees. This prevents runaway losses while allowing
  normal trading from a standing start.

  Loss tolerance = equity * ORDER_NOTIONAL_PCT * TRADE_FEE_RATE
  Principal persists to a JSON file (tagged by account) across restarts.
  """

  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Returns true unless equity has dropped below principal by more than one
  trade's fees. On first call (principal nil), snapshots equity and allows entry.
  Returns false for nil equity.
  """
  def allow_entry?(nil), do: false

  def allow_entry?(equity) when is_number(equity) do
    GenServer.call(__MODULE__, {:allow_entry, equity})
  end

  @doc "Accumulated gain capital: max(0, equity - principal). Returns 0.0 before snapshot."
  def trading_capital(equity) when is_number(equity) do
    case principal() do
      nil -> 0.0
      p -> max(0.0, equity - p)
    end
  end

  @doc "Current principal. Nil if not yet snapshotted."
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
    # Always start with nil principal — snapshot fresh on first trade check.
    # This ensures we gate against losses during THIS run, not historical ones.
    {:ok, %{principal: nil}}
  end

  @impl true
  def handle_call({:allow_entry, equity}, _from, %{principal: nil} = state) do
    new_state = %{state | principal: equity}
    persist(equity)
    Logger.info("[GainAccumulator] 📸 principal=$#{Float.round(equity * 1.0, 2)} established — trading enabled")
    {:reply, true, new_state}
  end

  def handle_call({:allow_entry, equity}, _from, %{principal: principal} = state) do
    notional_pct = Application.get_env(:alpaca_trader, :order_notional_pct, 0.001)
    fee_rate = Application.get_env(:alpaca_trader, :trade_fee_rate, 0.003)
    fee_tolerance = equity * notional_pct * fee_rate
    gain = equity - principal

    persist_session(principal, equity)

    if gain >= -fee_tolerance do
      Logger.info("[GainAccumulator] ✅ gain=$#{Float.round(gain, 2)} (tolerance=$#{Float.round(fee_tolerance, 4)}) — entry allowed")
      {:reply, true, state}
    else
      Logger.debug("[GainAccumulator] 🔒 gain=$#{Float.round(gain, 2)} exceeds loss tolerance=$#{Float.round(fee_tolerance, 4)} — entry blocked")
      {:reply, false, state}
    end
  end

  def handle_call(:principal, _from, state) do
    {:reply, state.principal, state}
  end

  def handle_call(:reset, _from, state) do
    path = file_path()
    if File.exists?(path), do: File.rm(path)
    Logger.info("[GainAccumulator] reset — principal cleared")
    {:reply, :ok, %{state | principal: nil}}
  end

  # ── Persistence ─────────────────────────────────────────────

  defp file_path do
    Application.get_env(:alpaca_trader, :gain_accumulator_path, "priv/gain_accumulator.json")
  end

  defp persist(principal) do
    persist_session(principal, principal)
  end

  defp persist_session(principal, equity) do
    payload =
      Jason.encode!(%{
        principal: principal,
        equity: equity,
        gain: Float.round((equity - principal) * 1.0, 2),
        account_env: account_env(),
        snapshot_time: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    case File.write(file_path(), payload) do
      :ok -> :ok
      {:error, reason} -> Logger.error("[GainAccumulator] failed to persist session: #{reason}")
    end
  end

  defp account_env do
    Application.get_env(:alpaca_trader, :alpaca_base_url, "unknown")
  end

end
