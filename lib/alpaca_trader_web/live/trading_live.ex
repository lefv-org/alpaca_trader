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
  defp dispatch(unknown, _), do: {:error, "Unknown action: #{unknown}"}

  defp split_symbols(nil), do: []
  defp split_symbols(""), do: []
  defp split_symbols(s), do: String.split(s, ~r/[,\s]+/, trim: true)

  def tabs, do: @tabs
end
