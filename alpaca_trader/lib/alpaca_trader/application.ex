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
      # Start a worker by calling: AlpacaTrader.Worker.start_link(arg)
      # {AlpacaTrader.Worker, arg},
      # Start to serve requests, typically the last entry
      AlpacaTraderWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AlpacaTrader.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AlpacaTraderWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
