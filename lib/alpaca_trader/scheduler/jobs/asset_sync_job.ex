defmodule AlpacaTrader.Scheduler.Jobs.AssetSyncJob do
  @moduledoc """
  Pulls all tradeable assets from Alpaca every minute
  and stores them in the AssetStore.
  """

  @behaviour AlpacaTrader.Scheduler.Job

  alias AlpacaTrader.Alpaca.Client
  alias AlpacaTrader.AssetStore

  require Logger

  @impl true
  def job_id, do: "asset-sync"

  @impl true
  def job_name, do: "Alpaca Asset Sync"

  @impl true
  def schedule, do: "* * * * *"

  @impl true
  def run do
    Logger.info("[AssetSyncJob] fetching tradeable assets")

    with {:ok, assets} <- Client.list_assets(%{status: "active"}) do
      tradeable = Enum.filter(assets, fn a -> a["tradable"] == true end)
      AssetStore.put_assets(tradeable)
      Logger.info("[AssetSyncJob] synced #{length(tradeable)} tradeable assets")
      {:ok, length(tradeable)}
    else
      {:error, reason} ->
        Logger.error("[AssetSyncJob] failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
