defmodule AlpacaTrader.Scheduler.Jobs.BarsSyncJob do
  @moduledoc """
  Fetches historical price bars for all symbols defined in
  AssetRelationships and stores them in the BarsStore.
  Runs at the top of every hour.
  """

  @behaviour AlpacaTrader.Scheduler.Job

  alias AlpacaTrader.Alpaca.Client
  alias AlpacaTrader.Arbitrage.AssetRelationships
  alias AlpacaTrader.BarsStore

  require Logger

  @batch_size 10

  @impl true
  def job_id, do: "bars-sync"

  @impl true
  def job_name, do: "Historical Bars Sync"

  @impl true
  def schedule, do: "0 * * * *"

  @impl true
  def run do
    symbols = AssetRelationships.all_symbols()
    Logger.info("[BarsSyncJob] fetching bars for #{length(symbols)} symbols")

    {crypto, equities} = Enum.split_with(symbols, &crypto?/1)

    with {:ok, equity_bars} <- fetch_bars_in_batches(equities, :stock),
         {:ok, crypto_bars} <- fetch_bars_in_batches(crypto, :crypto) do
      all_bars = Map.merge(equity_bars, crypto_bars)
      BarsStore.put_all_bars(all_bars)

      Logger.info("[BarsSyncJob] synced bars for #{map_size(all_bars)} symbols")
      {:ok, map_size(all_bars)}
    else
      {:error, reason} ->
        Logger.error("[BarsSyncJob] failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp crypto?(symbol), do: String.contains?(symbol, "/")

  defp fetch_bars_in_batches([], _type), do: {:ok, %{}}

  defp fetch_bars_in_batches(symbols, type) do
    symbols
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, acc} ->
      case fetch_batch(chunk, type) do
        {:ok, bars_map} -> {:cont, {:ok, Map.merge(acc, bars_map)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_batch(symbols, :stock) do
    case Client.get_stock_bars(symbols) do
      {:ok, %{"bars" => bars}} when is_map(bars) -> {:ok, bars}
      {:ok, data} when is_map(data) -> {:ok, Map.get(data, "bars", %{})}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_batch(symbols, :crypto) do
    case Client.get_crypto_bars(symbols) do
      {:ok, %{"bars" => bars}} when is_map(bars) -> {:ok, bars}
      {:ok, data} when is_map(data) -> {:ok, Map.get(data, "bars", %{})}
      {:error, reason} -> {:error, reason}
    end
  end
end
