defmodule AlpacaTrader.Scheduler.Jobs.ArbitrageScanJob do
  @moduledoc """
  Scans all tradeable assets for arbitrage opportunities every minute.
  Depends on AssetSyncJob having populated the AssetStore.
  """

  @behaviour AlpacaTrader.Scheduler.Job

  alias AlpacaTrader.Alpaca.Client
  alias AlpacaTrader.Engine
  alias AlpacaTrader.Engine.MarketContext

  require Logger

  @impl true
  def job_id, do: "arbitrage-scan"

  @impl true
  def job_name, do: "Arbitrage Scanner"

  @impl true
  def schedule, do: "* * * * *"

  @impl true
  def run do
    Logger.info("[ArbitrageScanJob] starting scan")

    crypto_symbols =
      AlpacaTrader.AssetStore.all()
      |> Enum.filter(fn a -> a["class"] == "crypto" end)
      |> Enum.map(fn a -> a["symbol"] end)

    with {:ok, account} <- Client.get_account(),
         {:ok, clock} <- Client.get_clock(),
         {:ok, positions} <- Client.list_positions(),
         {:ok, orders} <- Client.list_orders(%{status: "all", limit: 50}),
         {:ok, snapshots} <- fetch_crypto_quotes(crypto_symbols) do
      ctx = %MarketContext{
        symbol: nil,
        account: account,
        position: nil,
        clock: clock,
        asset: nil,
        bars: nil,
        positions: positions,
        orders: orders,
        quotes: snapshots
      }

      {:ok, result} = Engine.scan_and_execute(ctx)

      Logger.info(
        "[ArbitrageScanJob] scanned #{result.scanned}, " <>
          "#{result.hits} opportunities, #{result.executed} trades executed"
      )

      {:ok, result.scanned}
    else
      {:error, reason} ->
        Logger.error("[ArbitrageScanJob] failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_crypto_quotes([]), do: {:ok, %{}}

  defp fetch_crypto_quotes(symbols) do
    # Alpaca limits query string length, batch into chunks
    symbols
    |> Enum.chunk_every(50)
    |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, acc} ->
      case Client.get_crypto_snapshots(chunk) do
        {:ok, %{"snapshots" => data}} -> {:cont, {:ok, Map.merge(acc, data)}}
        {:ok, data} when is_map(data) -> {:cont, {:ok, Map.merge(acc, data)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
