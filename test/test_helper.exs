ExUnit.start()

{:ok, _} = AlpacaTrader.Brokers.Mock.start_link()

# Mox defmock for the Broker behaviour. Used by OrderRouter tests
# that need fine-grained expectations (verify_on_exit!).
Mox.defmock(AlpacaTrader.BrokerMock, for: AlpacaTrader.Broker)

Application.put_env(:alpaca_trader, :brokers,
  alpaca: AlpacaTrader.Brokers.Alpaca,
  mock: AlpacaTrader.Brokers.Mock,
  broker_mock: AlpacaTrader.BrokerMock
)
