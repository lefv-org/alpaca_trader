defmodule AlpacaTrader.PositionReconciler do
  @moduledoc """
  Boot-time reconciliation between live Alpaca positions and the in-memory
  `PairPositionStore`.

  PairPositionStore is ETS-backed and non-persistent — a crash wipes it, but
  Alpaca still holds whatever positions were open. Without reconciliation, the
  engine would not see the existing positions in its tracker and could open a
  second pair on the same asset.

  This module surfaces orphan symbols (held on Alpaca, untracked locally) and
  exposes `orphan?/1` for the engine's entry path to consult. It does not
  auto-close orphans — that's a human decision.
  """

  require Logger

  alias AlpacaTrader.Alpaca.Client
  alias AlpacaTrader.PairPositionStore

  @orphans_key {__MODULE__, :orphan_symbols}

  @doc """
  Reconcile Alpaca's open positions against PairPositionStore.
  Logs a summary and records orphans in :persistent_term.
  Safe to call multiple times — each call refreshes the orphan set.
  """
  def reconcile do
    with {:ok, alpaca_positions} <- list_alpaca_positions() do
      # Alpaca returns crypto without a slash (ETHUSD, BTCUSD); the
      # PairPositionStore stores them with one (ETH/USD, BTC/USD) because
      # that's the form used for order submission. Normalise both sides
      # to a canonical no-slash form for set comparison so a held ETH
      # position isn't perpetually flagged as orphan + ghost simultaneously,
      # which blocks every new entry via the engine's pre-flight check.
      alpaca_symbols = MapSet.new(alpaca_positions, &normalize_symbol(&1["symbol"]))
      tracked_symbols = tracked_symbols() |> Enum.map(&normalize_symbol/1) |> MapSet.new()

      orphans = MapSet.difference(alpaca_symbols, tracked_symbols)
      ghosts = MapSet.difference(tracked_symbols, alpaca_symbols)

      :persistent_term.put(@orphans_key, orphans)

      Logger.info(
        "[Reconciler] alpaca=#{MapSet.size(alpaca_symbols)} tracked=#{MapSet.size(tracked_symbols)} " <>
          "orphans=#{MapSet.size(orphans)} ghosts=#{MapSet.size(ghosts)}"
      )

      unless MapSet.size(orphans) == 0 do
        Logger.warning(
          "[Reconciler] orphaned Alpaca positions (not in PairPositionStore): " <>
            (orphans |> Enum.to_list() |> Enum.join(", ")) <>
            " — entries on these symbols will be blocked until reviewed"
        )
      end

      unless MapSet.size(ghosts) == 0 do
        Logger.warning(
          "[Reconciler] ghost tracked positions (not on Alpaca): " <>
            (ghosts |> Enum.to_list() |> Enum.join(", ")) <>
            " — closing stale tracker entries"
        )

        close_ghost_entries(ghosts)
      end

      :ok
    else
      {:error, reason} ->
        Logger.error("[Reconciler] failed to fetch Alpaca positions: #{inspect(reason)}")
        :persistent_term.put(@orphans_key, MapSet.new())
        {:error, reason}
    end
  end

  @doc "True if this symbol is held on Alpaca but not tracked locally."
  def orphan?(symbol) when is_binary(symbol) do
    case :persistent_term.get(@orphans_key, nil) do
      nil -> false
      set -> MapSet.member?(set, normalize_symbol(symbol))
    end
  end

  # Canonical no-slash form. ETH/USD → ETHUSD, AAPL → AAPL.
  # Used at the orphan-set boundary so crypto symbols compare consistently
  # regardless of whether they came from Alpaca's positions endpoint
  # (no slash) or our internal PairPositionStore (with slash).
  defp normalize_symbol(nil), do: ""
  defp normalize_symbol(s) when is_binary(s), do: String.replace(s, "/", "")

  @doc "The current orphan set. Empty set if reconcile/0 has not run."
  def orphans do
    :persistent_term.get(@orphans_key, MapSet.new())
  end

  defp list_alpaca_positions do
    case Client.list_positions() do
      {:ok, positions} when is_list(positions) -> {:ok, positions}
      {:ok, _} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tracked_symbols do
    PairPositionStore.open_positions()
    |> Enum.flat_map(fn pos -> [pos.asset_a, pos.asset_b] end)
    |> MapSet.new()
  end

  defp close_ghost_entries(ghost_symbols) do
    # Ghost set holds the no-slash canonical form (see normalize_symbol/1).
    # Match positions by normalised asset symbol so SOL/USD in the store
    # correctly matches SOLUSD in the ghost set.
    PairPositionStore.open_positions()
    |> Enum.filter(fn pos ->
      MapSet.member?(ghost_symbols, normalize_symbol(pos.asset_a)) or
        MapSet.member?(ghost_symbols, normalize_symbol(pos.asset_b))
    end)
    |> Enum.each(fn pos -> PairPositionStore.close_position(pos.id) end)
  end
end
