defmodule AlpacaTrader.Broker do
  @moduledoc """
  Venue abstraction. Implementations own HTTP/WS, auth, symbol normalization,
  and response decoding. Strategies never call implementations directly — the
  OrderRouter does, dispatching to the venue named in each %Leg{}.
  """

  alias AlpacaTrader.Types.{Order, Position, Account, Bar, Capabilities}

  @callback submit_order(Order.t(), opts :: keyword) ::
              {:ok, Order.t()} | {:error, term}

  @callback cancel_order(broker_order_id :: String.t()) ::
              :ok | {:error, term}

  @callback positions() :: {:ok, [Position.t()]} | {:error, term}

  @callback account() :: {:ok, Account.t()} | {:error, term}

  @callback bars(symbol :: String.t(), opts :: keyword) ::
              {:ok, [Bar.t()]} | {:error, term}

  @callback stream_ticks(symbols :: [String.t()], subscriber :: pid) ::
              {:ok, reference} | {:error, term}

  @callback funding_rate(symbol :: String.t()) ::
              {:ok, Decimal.t()} | {:error, term}

  @callback capabilities() :: Capabilities.t()

  @optional_callbacks stream_ticks: 2, funding_rate: 1

  @doc "Resolve a venue atom to its implementation module via config."
  @spec impl(atom) :: module
  def impl(venue) do
    :alpaca_trader
    |> Application.fetch_env!(:brokers)
    |> Keyword.fetch!(venue)
  end
end
