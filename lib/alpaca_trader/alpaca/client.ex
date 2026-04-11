defmodule AlpacaTrader.Alpaca.Client do
  @moduledoc "Thin Req-based client for Alpaca Trading API v2."

  defp client do
    opts = [
      base_url: Application.fetch_env!(:alpaca_trader, :alpaca_base_url),
      headers: [
        {"APCA-API-KEY-ID", Application.fetch_env!(:alpaca_trader, :alpaca_key_id)},
        {"APCA-API-SECRET-KEY", Application.fetch_env!(:alpaca_trader, :alpaca_secret_key)}
      ]
    ]

    case Application.get_env(:alpaca_trader, :req_plug) do
      nil -> Req.new(opts)
      plug -> Req.new(Keyword.put(opts, :plug, plug))
    end
  end

  defp get(path, params \\ []) do
    client() |> Req.get(url: path, params: params) |> handle()
  end

  defp post(path, body) do
    client() |> Req.post(url: path, json: body) |> handle()
  end

  defp patch(path, body) do
    client() |> Req.patch(url: path, json: body) |> handle()
  end

  defp put(path, body) do
    client() |> Req.put(url: path, json: body) |> handle()
  end

  defp delete(path, params \\ []) do
    client() |> Req.delete(url: path, params: params) |> handle()
  end

  defp handle({:ok, %{status: s, body: body}}) when s in 200..299, do: {:ok, body}
  defp handle({:ok, %{body: body}}), do: {:error, body}
  defp handle({:error, reason}), do: {:error, reason}

  # --- Account ---

  def get_account, do: get("/v2/account")
  def get_account_config, do: get("/v2/account/configurations")
  def update_account_config(params), do: patch("/v2/account/configurations", params)
  def get_activities(params \\ %{}), do: get("/v2/account/activities", params)
  def get_portfolio_history(params \\ %{}), do: get("/v2/account/portfolio/history", params)

  # --- Orders ---

  def list_orders(params \\ %{}), do: get("/v2/orders", params)
  def create_order(params), do: post("/v2/orders", params)
  def get_order(order_id), do: get("/v2/orders/#{order_id}")
  def replace_order(order_id, params), do: patch("/v2/orders/#{order_id}", params)
  def cancel_order(order_id), do: delete("/v2/orders/#{order_id}")
  def cancel_all_orders, do: delete("/v2/orders")

  # --- Positions ---

  def list_positions, do: get("/v2/positions")
  def get_position(symbol), do: get("/v2/positions/#{symbol}")
  def close_position(symbol, params \\ %{}), do: delete("/v2/positions/#{symbol}", params)
  def close_all_positions(params \\ %{}), do: delete("/v2/positions", params)

  # --- Assets ---

  def list_assets(params \\ %{}), do: get("/v2/assets", params)
  def get_asset(symbol), do: get("/v2/assets/#{symbol}")

  # --- Watchlists ---

  def list_watchlists, do: get("/v2/watchlists")
  def create_watchlist(params), do: post("/v2/watchlists", params)
  def get_watchlist(id), do: get("/v2/watchlists/#{id}")
  def update_watchlist(id, params), do: put("/v2/watchlists/#{id}", params)
  def delete_watchlist(id), do: delete("/v2/watchlists/#{id}")
  def add_to_watchlist(id, symbol), do: post("/v2/watchlists/#{id}", %{symbol: symbol})
  def remove_from_watchlist(id, symbol), do: delete("/v2/watchlists/#{id}/#{symbol}")

  # --- Market ---

  def get_clock, do: get("/v2/clock")
  def get_calendar(params \\ %{}), do: get("/v2/calendar", params)
  def get_corporate_actions(params \\ %{}), do: get("/v2/corporate_actions/announcements", params)

  # --- Market Data (data.alpaca.markets) ---

  defp data_client do
    opts = [
      base_url: Application.get_env(:alpaca_trader, :alpaca_data_url, "https://data.alpaca.markets"),
      headers: [
        {"APCA-API-KEY-ID", Application.fetch_env!(:alpaca_trader, :alpaca_key_id)},
        {"APCA-API-SECRET-KEY", Application.fetch_env!(:alpaca_trader, :alpaca_secret_key)}
      ]
    ]

    case Application.get_env(:alpaca_trader, :req_plug) do
      nil -> Req.new(opts)
      plug -> Req.new(Keyword.put(opts, :plug, plug))
    end
  end

  def get_crypto_snapshots(symbols) when is_list(symbols) do
    joined = Enum.join(symbols, ",")
    data_client() |> Req.get(url: "/v1beta3/crypto/us/snapshots", params: [symbols: joined]) |> handle()
  end

  def get_stock_bars(symbols, params \\ %{}) when is_list(symbols) do
    joined = Enum.join(symbols, ",")
    defaults = %{timeframe: "1Day", limit: 60}
    merged = Map.merge(defaults, params) |> Map.put(:symbols, joined)
    data_client() |> Req.get(url: "/v2/stocks/bars", params: Map.to_list(merged)) |> handle()
  end

  def get_crypto_bars(symbols, params \\ %{}) when is_list(symbols) do
    joined = Enum.join(symbols, ",")
    defaults = %{timeframe: "1Day", limit: 60}
    merged = Map.merge(defaults, params) |> Map.put(:symbols, joined)
    data_client() |> Req.get(url: "/v1beta3/crypto/us/bars", params: Map.to_list(merged)) |> handle()
  end
end
