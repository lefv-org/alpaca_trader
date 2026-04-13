defmodule AlpacaTrader.GainAccumulatorStore do
  @moduledoc """
  Tracks original principal from first-boot equity snapshot.
  Gates new trade entries: allows entry only when equity - principal >= ORDER_NOTIONAL.
  Principal persists to a JSON file across restarts.
  """

  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Returns true only when equity - principal >= order_notional.
  On first call (principal nil), snapshots equity, writes file, returns false.
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
    state =
      case load_from_file() do
        {:ok, principal} ->
          Logger.info("[GainAccumulator] loaded principal=$#{Float.round(principal, 2)}")
          %{principal: principal}

        {:error, :not_found} ->
          %{principal: nil}

        {:error, reason} ->
          Logger.warning("[GainAccumulator] could not load file (#{reason}), starting fresh")
          %{principal: nil}
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:allow_entry, equity}, _from, %{principal: nil} = state) do
    new_state = %{state | principal: equity}
    persist(equity)
    Logger.info("[GainAccumulator] 📸 principal=$#{Float.round(equity, 2)} established")
    {:reply, false, new_state}
  end

  def handle_call({:allow_entry, equity}, _from, %{principal: principal} = state) do
    notional = parse_notional(Application.get_env(:alpaca_trader, :order_notional, "10"))
    gain = equity - principal

    if gain >= notional do
      Logger.info("[GainAccumulator] ✅ gain=$#{Float.round(gain, 2)} >= $#{notional} — entry allowed")
      {:reply, true, state}
    else
      Logger.debug("[GainAccumulator] 🔒 gain=$#{Float.round(gain, 2)} < $#{notional} — entry blocked")
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

  defp load_from_file do
    path = file_path()

    case File.read(path) do
      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}

      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"principal" => p}} when is_number(p) -> {:ok, p * 1.0}
          _ -> {:error, :invalid_json}
        end
    end
  end

  defp persist(principal) do
    payload =
      Jason.encode!(%{
        principal: principal,
        snapshot_time: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    File.write(file_path(), payload)
  end

  defp parse_notional(n) when is_number(n), do: n * 1.0

  defp parse_notional(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 10.0
    end
  end
end
