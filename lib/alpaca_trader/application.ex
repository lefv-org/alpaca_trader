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
      AlpacaTrader.Scheduler.Quantum,
      AlpacaTraderWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: AlpacaTrader.Supervisor]
    result = Supervisor.start_link(children, opts)

    register_jobs()

    result
  end

  defp register_jobs do
    alias AlpacaTrader.Scheduler.Api
    alias AlpacaTrader.Scheduler.Jobs.AssetSyncJob

    Api.register_job(AssetSyncJob)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AlpacaTraderWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
