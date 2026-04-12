defmodule AlpacaTrader.MinuteBarCache do
  @moduledoc """
  ETS cache for 1-minute crypto bars, refreshed every scan cycle.
  Used for live z-score computation when equity markets are closed.
  """

  use GenServer

  alias AlpacaTrader.Alpaca.Client

  @table :minute_bar_cache

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Refresh 1-minute bars for a list of crypto symbols."
  def refresh(symbols) when is_list(symbols) do
    crypto = Enum.filter(symbols, &String.contains?(&1, "/"))

    Enum.each(crypto, fn sym ->
      case Client.get_crypto_bars([sym], %{timeframe: "1Min", limit: 60}) do
        {:ok, %{"bars" => %{^sym => bars}}} when is_list(bars) ->
          closes = bars |> Enum.sort_by(& &1["t"]) |> Enum.map(& &1["c"])
          :ets.insert(@table, {sym, closes})

        _ ->
          :ok
      end
    end)
  end

  @doc "Get 1-minute closes for a symbol."
  def get_closes(symbol) do
    case :ets.info(@table) do
      :undefined -> :error
      _ ->
        case :ets.lookup(@table, symbol) do
          [{^symbol, closes}] -> {:ok, closes}
          [] -> :error
        end
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
