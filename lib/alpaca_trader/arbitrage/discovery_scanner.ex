defmodule AlpacaTrader.Arbitrage.DiscoveryScanner do
  @moduledoc """
  Rotates through the full asset universe, checking new stocks against
  portfolio holdings for undiscovered arbitrage pairs.

  Each scan picks a batch of assets not yet evaluated, fetches their bars,
  and computes z-scores against all relationship symbols. Over time,
  the scanner covers the entire market.
  """

  use GenServer

  alias AlpacaTrader.{AssetStore, BarsStore}
  alias AlpacaTrader.Alpaca.Client
  alias AlpacaTrader.Arbitrage.{AssetRelationships, SpreadCalculator}

  require Logger

  @batch_size 10
  @z_threshold 2.0

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Get the next batch of discovery symbols and scan them against the portfolio.
  Returns a list of discovered pair signals.
  """
  def discover do
    GenServer.call(__MODULE__, :discover, 30_000)
  end

  @doc "How many assets have been scanned so far in this rotation."
  def scanned_count do
    GenServer.call(__MODULE__, :scanned_count)
  end

  @doc "Reset the rotation (start scanning from the beginning)."
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # GenServer callbacks

  @impl true
  def init(_) do
    {:ok, %{scanned: MapSet.new(), rotation: 0}}
  end

  @impl true
  def handle_call(:discover, _from, state) do
    # Get all equity symbols we haven't scanned yet
    known = AssetRelationships.all_symbols() |> MapSet.new()

    candidates =
      AssetStore.all()
      |> Enum.filter(fn a ->
        a["tradable"] == true and
          a["symbol"] not in known and
          a["symbol"] not in state.scanned
      end)
      |> Enum.take(@batch_size)

    if candidates == [] do
      # Full rotation complete — reset
      Logger.info("[Discovery] full rotation complete (#{MapSet.size(state.scanned)} assets scanned), resetting")
      {:reply, {[], MapSet.size(state.scanned)}, %{state | scanned: MapSet.new(), rotation: state.rotation + 1}}
    else
      symbols = Enum.map(candidates, & &1["symbol"])

      # Fetch bars for these new symbols
      fetch_and_cache_bars(symbols)

      # Check each against all relationship symbols
      portfolio_symbols = AssetRelationships.all_symbols()
      signals = find_pairs(symbols, portfolio_symbols)

      new_scanned = Enum.reduce(symbols, state.scanned, &MapSet.put(&2, &1))

      if signals != [] do
        Logger.info("[Discovery] found #{length(signals)} opportunities in batch: #{Enum.join(symbols, ", ")}")
      end

      {:reply, {signals, MapSet.size(new_scanned)}, %{state | scanned: new_scanned}}
    end
  end

  @impl true
  def handle_call(:scanned_count, _from, state) do
    {:reply, MapSet.size(state.scanned), state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | scanned: MapSet.new()}}
  end

  # Fetch bars for new symbols and store them
  defp fetch_and_cache_bars([]), do: :ok

  defp fetch_and_cache_bars(symbols) do
    {crypto, equities} = Enum.split_with(symbols, &String.contains?(&1, "/"))

    # Fetch equity bars
    if equities != [] do
      case Client.get_stock_bars(equities) do
        {:ok, %{"bars" => data}} when is_map(data) ->
          Enum.each(data, fn {sym, bars} -> :ets.insert(:bars_store, {sym, bars}) end)
        _ -> :ok
      end
    end

    # Fetch crypto bars
    if crypto != [] do
      case Client.get_crypto_bars(crypto) do
        {:ok, %{"bars" => data}} when is_map(data) ->
          Enum.each(data, fn {sym, bars} -> :ets.insert(:bars_store, {sym, bars}) end)
        _ -> :ok
      end
    end
  end

  # Check each new symbol against each portfolio symbol for z-score opportunities
  defp find_pairs(new_symbols, portfolio_symbols) do
    Enum.flat_map(new_symbols, fn new_sym ->
      Enum.flat_map(portfolio_symbols, fn port_sym ->
        check_pair(new_sym, port_sym)
      end)
    end)
    |> Enum.sort_by(fn s -> -abs(s.z_score) end)
  end

  defp check_pair(sym_a, sym_b) do
    with {:ok, closes_a} <- BarsStore.get_closes(sym_a),
         {:ok, closes_b} <- BarsStore.get_closes(sym_b) do
      len = min(length(closes_a), length(closes_b))

      if len >= 20 do
        a = Enum.take(closes_a, -len)
        b = Enum.take(closes_b, -len)

        case SpreadCalculator.analyze(a, b) do
          %{z_score: z, hedge_ratio: ratio} when abs(z) > @z_threshold ->
            direction = if z > 0, do: :long_b_short_a, else: :long_a_short_b

            [%{
              asset_a: sym_a,
              asset_b: sym_b,
              z_score: z,
              hedge_ratio: ratio,
              direction: direction,
              source: :discovery
            }]

          _ ->
            []
        end
      else
        []
      end
    else
      _ -> []
    end
  end
end
