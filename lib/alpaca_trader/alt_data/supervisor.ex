defmodule AlpacaTrader.AltData.Supervisor do
  @moduledoc "Supervises all enabled alternative data providers."

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = enabled_providers()

    if children != [] do
      require Logger
      names = Enum.map(children, fn mod -> inspect(mod) |> String.split(".") |> List.last() end)
      Logger.info("[AltData] starting providers: #{Enum.join(names, ", ")}")
    end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp enabled_providers do
    alias AlpacaTrader.AltData.Providers

    [
      {Providers.Fred, Application.get_env(:alpaca_trader, :alt_data_fred_enabled, true)},
      {Providers.OpenMeteo,
       Application.get_env(:alpaca_trader, :alt_data_open_meteo_enabled, true)},
      {Providers.OpenSky, Application.get_env(:alpaca_trader, :alt_data_opensky_enabled, true)},
      {Providers.NasaFirms,
       Application.get_env(:alpaca_trader, :alt_data_nasa_firms_enabled, false)},
      {Providers.Nws, Application.get_env(:alpaca_trader, :alt_data_nws_enabled, true)},
      {Providers.Finnhub, Application.get_env(:alpaca_trader, :alt_data_finnhub_enabled, false)},
      {Providers.QuiverCongress, quiver_enabled?(:quiver_congress_enabled)},
      {Providers.QuiverInsider, quiver_enabled?(:quiver_insider_enabled)},
      {Providers.QuiverGovContracts, quiver_enabled?(:quiver_govcontracts_enabled)},
      {Providers.QuiverLobbying, quiver_enabled?(:quiver_lobbying_enabled)},
      {Providers.QuiverWsb, quiver_enabled?(:quiver_wsb_enabled)}
    ]
    |> Enum.filter(fn {_mod, enabled} -> enabled end)
    |> Enum.map(fn {mod, _} -> mod end)
  end

  defp quiver_enabled?(flag) do
    Application.get_env(:alpaca_trader, flag, false) and
      not is_nil(Application.get_env(:alpaca_trader, :quiverquant_api_key)) and
      Application.get_env(:alpaca_trader, :quiverquant_api_key) != ""
  end
end
