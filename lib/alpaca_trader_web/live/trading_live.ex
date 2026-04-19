defmodule AlpacaTraderWeb.TradingLive do
  use AlpacaTraderWeb, :live_view

  alias AlpacaTrader.Alpaca.Client

  @tabs ~w(dashboard account orders positions assets watchlists market)a

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:tab, :dashboard)
      |> assign(:loading, false)
      |> assign(:result, nil)
      |> assign(:error, nil)

    socket = if connected?(socket), do: load_dashboard(socket), else: socket
    {:ok, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => "dashboard"}, socket) do
    {:noreply, socket |> assign(tab: :dashboard, result: nil, error: nil) |> load_dashboard()}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: String.to_existing_atom(tab), result: nil, error: nil)}
  end

  @impl true
  def handle_event("call", %{"action" => action} = params, socket) do
    clean = Map.drop(params, ["action", "_target", "_csrf_token"])
    send(self(), {:call, action, clean})
    {:noreply, assign(socket, loading: true, result: nil, error: nil)}
  end

  @impl true
  def handle_info({:call, action, params}, socket) do
    result = dispatch(action, params)

    socket =
      case result do
        {:ok, data} -> assign(socket, result: data, error: nil, loading: false)
        {:error, err} -> assign(socket, error: inspect(err), result: nil, loading: false)
      end

    {:noreply, socket}
  end

  # --- Dashboard loader ---

  defp load_dashboard(socket) do
    with {:ok, account} <- Client.get_account(),
         {:ok, positions} <- Client.list_positions(),
         {:ok, orders} <- Client.list_orders(%{status: "all", limit: 10}),
         {:ok, history} <- Client.get_portfolio_history(%{period: "1D", timeframe: "1H"}) do
      assign(socket,
        result: %{account: account, positions: positions, orders: orders, history: history}
      )
    else
      {:error, err} -> assign(socket, error: inspect(err))
    end
  end

  # --- Action dispatch ---

  defp dispatch("refresh_dashboard", _) do
    with {:ok, account} <- Client.get_account(),
         {:ok, positions} <- Client.list_positions(),
         {:ok, orders} <- Client.list_orders(%{status: "all", limit: 10}),
         {:ok, history} <- Client.get_portfolio_history(%{period: "1D", timeframe: "1H"}) do
      {:ok, %{account: account, positions: positions, orders: orders, history: history}}
    end
  end

  defp dispatch("get_account", _), do: Client.get_account()
  defp dispatch("get_account_config", _), do: Client.get_account_config()
  defp dispatch("update_account_config", p), do: Client.update_account_config(p)
  defp dispatch("get_activities", p), do: Client.get_activities(p)
  defp dispatch("get_portfolio_history", p), do: Client.get_portfolio_history(p)

  defp dispatch("list_orders", p), do: Client.list_orders(p)
  defp dispatch("create_order", p), do: Client.create_order(p)
  defp dispatch("get_order", %{"order_id" => id}), do: Client.get_order(id)

  defp dispatch("replace_order", %{"order_id" => id} = p),
    do: Client.replace_order(id, Map.delete(p, "order_id"))

  defp dispatch("cancel_order", %{"order_id" => id}), do: Client.cancel_order(id)
  defp dispatch("cancel_all_orders", _), do: Client.cancel_all_orders()

  defp dispatch("list_positions", _), do: Client.list_positions()
  defp dispatch("get_position", %{"symbol" => s}), do: Client.get_position(s)

  defp dispatch("close_position", %{"symbol" => s} = p),
    do: Client.close_position(s, Map.delete(p, "symbol"))

  defp dispatch("close_all_positions", p), do: Client.close_all_positions(p)

  defp dispatch("list_assets", p), do: Client.list_assets(p)
  defp dispatch("get_asset", %{"symbol" => s}), do: Client.get_asset(s)

  defp dispatch("list_watchlists", _), do: Client.list_watchlists()

  defp dispatch("create_watchlist", %{"name" => name} = p),
    do: Client.create_watchlist(%{name: name, symbols: split_symbols(p["symbols"])})

  defp dispatch("get_watchlist", %{"watchlist_id" => id}), do: Client.get_watchlist(id)

  defp dispatch("update_watchlist", %{"watchlist_id" => id} = p),
    do: Client.update_watchlist(id, %{name: p["name"], symbols: split_symbols(p["symbols"])})

  defp dispatch("delete_watchlist", %{"watchlist_id" => id}), do: Client.delete_watchlist(id)

  defp dispatch("add_to_watchlist", %{"watchlist_id" => id, "symbol" => s}),
    do: Client.add_to_watchlist(id, s)

  defp dispatch("remove_from_watchlist", %{"watchlist_id" => id, "symbol" => s}),
    do: Client.remove_from_watchlist(id, s)

  defp dispatch("get_clock", _), do: Client.get_clock()
  defp dispatch("get_calendar", p), do: Client.get_calendar(p)
  defp dispatch("get_corporate_actions", p), do: Client.get_corporate_actions(p)

  defp dispatch("execute_trade", %{"symbol" => symbol} = params) do
    alias AlpacaTrader.Engine
    alias AlpacaTrader.Engine.MarketContext

    with {:ok, account} <- Client.get_account(),
         {:ok, clock} <- Client.get_clock(),
         {:ok, asset} <- Client.get_asset(symbol),
         {:ok, positions} <- Client.list_positions(),
         {:ok, orders} <- Client.list_orders(%{status: "all", limit: 10}) do
      position = Enum.find(positions, fn p -> p["symbol"] == symbol end)

      ctx = %MarketContext{
        symbol: symbol,
        account: account,
        position: position,
        clock: clock,
        asset: asset,
        bars: nil,
        positions: positions,
        orders: orders
      }

      order_params = Map.drop(params, ["symbol", "action"])
      {:ok, output} = Engine.execute_trade(ctx, order_params)
      {:ok, %{input: ctx, output: output}}
    end
  end

  defp dispatch("is_in_arbitrage_position", %{"asset" => asset}) do
    alias AlpacaTrader.Engine
    alias AlpacaTrader.Engine.MarketContext

    with {:ok, account} <- Client.get_account(),
         {:ok, clock} <- Client.get_clock(),
         {:ok, positions} <- Client.list_positions(),
         {:ok, orders} <- Client.list_orders(%{status: "all", limit: 10}) do
      ctx = %MarketContext{
        symbol: asset,
        account: account,
        position: nil,
        clock: clock,
        asset: nil,
        bars: nil,
        positions: positions,
        orders: orders
      }

      {:ok, output} = Engine.is_in_arbitrage_position(ctx, asset)
      {:ok, %{input: ctx, output: output}}
    end
  end

  defp dispatch("scan_arbitrage", _) do
    with {:ok, ctx} <- build_scan_context() do
      {:ok, output} = AlpacaTrader.Engine.scan_arbitrage(ctx)
      {:ok, %{input: ctx, output: output}}
    end
  end

  defp dispatch("scan_and_execute", _) do
    with {:ok, ctx} <- build_scan_context() do
      {:ok, output} = AlpacaTrader.Engine.scan_and_execute(ctx)
      {:ok, %{input: ctx, output: output}}
    end
  end

  defp dispatch(unknown, _), do: {:error, "Unknown action: #{unknown}"}

  defp build_scan_context do
    alias AlpacaTrader.Engine.MarketContext

    crypto_symbols =
      AlpacaTrader.AssetStore.all()
      |> Enum.filter(fn a -> a["class"] == "crypto" end)
      |> Enum.map(fn a -> a["symbol"] end)

    with {:ok, account} <- Client.get_account(),
         {:ok, clock} <- Client.get_clock(),
         {:ok, positions} <- Client.list_positions(),
         {:ok, orders} <- Client.list_orders(%{status: "all", limit: 50}),
         {:ok, snapshots} <- fetch_crypto_quotes(crypto_symbols) do
      {:ok,
       %MarketContext{
         symbol: nil,
         account: account,
         position: nil,
         clock: clock,
         asset: nil,
         bars: nil,
         positions: positions,
         orders: orders,
         quotes: snapshots
       }}
    end
  end

  defp fetch_crypto_quotes([]), do: {:ok, %{}}

  defp fetch_crypto_quotes(symbols) do
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

  defp split_symbols(nil), do: []
  defp split_symbols(""), do: []
  defp split_symbols(s), do: String.split(s, ~r/[,\s]+/, trim: true)

  def tabs, do: @tabs

  # Alpaca returns percentages as strings, sometimes "0.0123" and sometimes "0".
  # String.to_float/1 crashes on integer-formatted strings; Float.parse/1 handles both.
  def format_pct(val, decimals \\ 2)
  def format_pct(nil, _), do: "0.00"

  def format_pct(val, decimals) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> Float.round(f * 100, decimals) |> :erlang.float_to_binary(decimals: decimals)
      :error -> "0.00"
    end
  end

  def format_pct(val, decimals) when is_number(val) do
    Float.round(val * 100 * 1.0, decimals) |> :erlang.float_to_binary(decimals: decimals)
  end
end
