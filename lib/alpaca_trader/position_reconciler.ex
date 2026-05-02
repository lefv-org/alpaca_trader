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
  @alpaca_held_key {__MODULE__, :alpaca_held}
  # Separate "in-flight" set that doesn't get overwritten by the
  # reconciler's full snapshot. Inline marks (after we just submitted
  # an entry) live here with a TTL of @inflight_ttl_ms so they survive
  # the next reconcile while the order is still settling at Alpaca.
  @inflight_held_key {__MODULE__, :inflight_held}
  @inflight_ttl_ms 5 * 60 * 1000

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
      :persistent_term.put(@alpaca_held_key, alpaca_symbols)

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
            " — closing pair-store entries only when BOTH legs are ghost"
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

  @doc """
  True if Alpaca currently holds a position in this symbol. Reads from
  the cached Alpaca-side set written by reconcile/0, so it does not
  trigger a fresh API call. Stale up to one reconciler tick (1 min).
  """
  def held_on_alpaca?(symbol) when is_binary(symbol) do
    norm = normalize_symbol(symbol)
    held_in_alpaca_set?(norm) or held_in_inflight_set?(norm)
  end

  defp held_in_alpaca_set?(norm) do
    case :persistent_term.get(@alpaca_held_key, nil) do
      nil -> false
      set -> MapSet.member?(set, norm)
    end
  end

  defp held_in_inflight_set?(norm) do
    cur = :persistent_term.get(@inflight_held_key, %{})
    now = System.monotonic_time(:millisecond)

    case Map.get(cur, norm) do
      ts when is_integer(ts) and now - ts < @inflight_ttl_ms -> true
      _ -> false
    end
  end

  @doc """
  Inline-mark a symbol as Alpaca-held without waiting for the next
  reconciler tick. Use when the engine has just submitted a buy and
  another scan in the same minute would otherwise see a stale
  not-held cache and fire a duplicate entry.

  Idempotent — adding an already-present symbol is a no-op. Reads
  + writes the persistent_term set under the same key reconcile/0
  uses, so the next normal reconcile reconciles cleanly.
  """
  def mark_held_on_alpaca(symbol) when is_binary(symbol) do
    norm = normalize_symbol(symbol)
    now = System.monotonic_time(:millisecond)

    # Write into BOTH the alpaca_held set (so existing readers benefit
    # immediately) AND the in-flight TTL map (so the next reconciler
    # snapshot can't wipe it before Alpaca's /v2/positions reflects
    # the just-submitted order). Without the in-flight set the inline
    # mark survives only until the next reconcile/0 — which on a fast
    # tick is <60s, often less than fill latency on a flaky paper feed.
    cur_set = :persistent_term.get(@alpaca_held_key, MapSet.new())
    :persistent_term.put(@alpaca_held_key, MapSet.put(cur_set, norm))

    cur_inflight = :persistent_term.get(@inflight_held_key, %{})
    :persistent_term.put(@inflight_held_key, Map.put(cur_inflight, norm, now))

    :ok
  end

  def mark_held_on_alpaca(_), do: :ok

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
    # Only close pair-store entries where BOTH legs are ghost. Closing a
    # pair where one leg is still held on Alpaca leaves that real
    # holding untracked — and the engine's `find_open_for_asset/1`
    # check then returns nil, re-allowing entries on the asset we still
    # hold. That re-entry loop is the failure mode we hit on
    # SOL/USD↔ETH/USD where SOL/USD was never on Alpaca but ETH/USD
    # actually executed: closing the pair untracked the live ETH/USD
    # position and the bot kept buying it on every fresh signal.
    PairPositionStore.open_positions()
    |> Enum.filter(fn pos ->
      a_ghost = MapSet.member?(ghost_symbols, normalize_symbol(pos.asset_a))
      b_ghost = MapSet.member?(ghost_symbols, normalize_symbol(pos.asset_b))
      a_ghost and b_ghost
    end)
    |> Enum.each(fn pos -> PairPositionStore.close_position(pos.id) end)
  end
end
