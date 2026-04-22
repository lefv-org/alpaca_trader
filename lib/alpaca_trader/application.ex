defmodule AlpacaTrader.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AlpacaTraderWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:alpaca_trader, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AlpacaTrader.PubSub},
      AlpacaTrader.AssetStore,
      AlpacaTrader.BarsStore,
      AlpacaTrader.PairPositionStore,
      AlpacaTrader.GainAccumulatorStore,
      AlpacaTrader.TradeLog,
      AlpacaTrader.ShadowLogger,
      AlpacaTrader.LLM.OpinionGate,
      AlpacaTrader.MinuteBarCache,
      AlpacaTrader.Arbitrage.PairWhitelist,
      AlpacaTrader.Arbitrage.DiscoveryScanner,
      AlpacaTrader.Arbitrage.PairBuilder,
      AlpacaTrader.Polymarket.SignalGenerator,
      AlpacaTrader.AltData.SignalStore,
      AlpacaTrader.AltData.Supervisor,
      AlpacaTrader.Scheduler.JobLocks,
      AlpacaTrader.Scheduler.Quantum,
      {Registry, keys: :unique, name: AlpacaTrader.StrategyRunners},
      AlpacaTrader.StrategySupervisor,
      AlpacaTrader.StrategyRegistry,
      AlpacaTrader.MarketDataBus,
      AlpacaTraderWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: AlpacaTrader.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Warm stores before registering cron jobs so the first scan has data
    unless Application.get_env(:alpaca_trader, :skip_startup_sync, false) do
      AlpacaTrader.Scheduler.Jobs.AssetSyncJob.run()
      Task.start(fn -> AlpacaTrader.Scheduler.Jobs.BarsSyncJob.run() end)
      # Reconcile before jobs run so orphan-blocking is in place from tick 1
      AlpacaTrader.PositionReconciler.reconcile()
    end

    register_jobs()

    result
  end

  defp register_jobs do
    alias AlpacaTrader.Scheduler.Api
    alias AlpacaTrader.Scheduler.Jobs.AssetSyncJob
    alias AlpacaTrader.Scheduler.Jobs.ArbitrageScanJob
    alias AlpacaTrader.Scheduler.Jobs.BarsSyncJob

    Api.register_job(AssetSyncJob)
    Api.register_job(ArbitrageScanJob)
    Api.register_job(BarsSyncJob)
    Api.register_job(AlpacaTrader.Scheduler.Jobs.PairBuildJob)
    Api.register_job(AlpacaTrader.Scheduler.Jobs.PairRecointegrationJob)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AlpacaTraderWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
