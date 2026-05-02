defmodule AlpacaTrader.Scheduler.Jobs.OrphanReaperJob do
  @moduledoc """
  Closes crypto positions that lose tracking (orphans) and slip past
  the engine's tier-based cut-loss logic.

  Why: discovery scanner opens crypto pair positions, but the
  PairPositionStore record can be wiped by a ghost-close or never get
  created in the first place (race between order submit and reconcile).
  Once untracked, the engine's tier params (cut_loss=-1.5% for memes,
  -1.0% for high-vol) never fire because the per-position check_exit
  loop only iterates PairPositionStore.open_positions/0.

  This reaper queries Alpaca's live /v2/positions and closes any crypto
  position whose unrealized_plpc <= ORPHAN_REAPER_LOSS_PCT (default
  -0.01 = -1%). Conservative — equity positions are skipped so we don't
  fight the legacy engine's tier-based exits.
  """
  @behaviour AlpacaTrader.Scheduler.Job

  require Logger

  @impl true
  def job_id, do: "orphan-reaper"

  @impl true
  def job_name, do: "Orphan Crypto Reaper"

  @impl true
  def schedule, do: "* * * * *"

  @impl true
  def run do
    threshold =
      Application.get_env(:alpaca_trader, :orphan_reaper_loss_pct, -0.01)

    case AlpacaTrader.Alpaca.Client.list_positions() do
      {:ok, positions} when is_list(positions) ->
        crypto_losers =
          positions
          |> Enum.filter(&crypto?/1)
          |> Enum.filter(&loss_exceeds?(&1, threshold))

        results = Enum.map(crypto_losers, &close_one/1)

        if results != [] do
          Logger.info(
            "[OrphanReaper] closed #{Enum.count(results, &(&1 == :ok))} of #{length(results)} crypto losers (threshold=#{threshold * 100}%)"
          )
        end

        {:ok, %{closed: length(results)}}

      _ ->
        {:ok, %{closed: 0}}
    end
  rescue
    e ->
      Logger.error("[OrphanReaper] crashed: #{Exception.message(e)}")
      {:error, e}
  end

  defp crypto?(%{"asset_class" => "crypto"}), do: true
  defp crypto?(%{"symbol" => sym}) when is_binary(sym), do: String.contains?(sym, "USD")
  defp crypto?(_), do: false

  defp loss_exceeds?(position, threshold) do
    case parse_float(position["unrealized_plpc"]) do
      pct when is_number(pct) -> pct <= threshold
      _ -> false
    end
  end

  defp close_one(%{"symbol" => symbol} = pos) do
    pct = parse_float(pos["unrealized_plpc"])
    pl = pos["unrealized_pl"]

    Logger.info(
      "[OrphanReaper] closing #{symbol} pl=#{pl} pct=#{pct} (>#{Application.get_env(:alpaca_trader, :orphan_reaper_loss_pct, -0.01) * 100}% loss)"
    )

    # Alpaca's /v2/positions/SYMBOL DELETE accepts the symbol with the
    # slash stripped for crypto.
    norm = String.replace(symbol, "/", "")

    case AlpacaTrader.Alpaca.Client.close_position(norm) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("[OrphanReaper] close_position(#{symbol}) failed: #{inspect(reason)}")
        :error
    end
  end

  defp close_one(_), do: :error

  defp parse_float(nil), do: nil
  defp parse_float(n) when is_number(n), do: n * 1.0

  defp parse_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end
end
