defmodule AlpacaTrader.Polymarket.Client do
  @moduledoc """
  HTTP client for Polymarket's public APIs.
  No authentication needed for market data.
  """

  defp gamma_url, do: Application.get_env(:alpaca_trader, :polymarket_gamma_url, "https://gamma-api.polymarket.com")
  defp clob_url,  do: Application.get_env(:alpaca_trader, :polymarket_clob_url,  "https://clob.polymarket.com")

  @doc "Search for markets by query string."
  def search(query) do
    get("#{gamma_url()}/public-search", q: query, limit_per_type: 10)
  end

  @doc "Get active events, sorted by volume."
  def active_events(opts \\ []) do
    params = [
      active: true,
      closed: false,
      order: Keyword.get(opts, :order, "volume_24hr"),
      ascending: false,
      limit: Keyword.get(opts, :limit, 50)
    ]

    get("#{gamma_url()}/events", params)
  end

  @doc "Get a specific event by slug."
  def get_event(slug) do
    get("#{gamma_url()}/events", slug: slug)
  end

  @doc "Get midpoint (probability) for a token."
  def get_midpoint(token_id) do
    get("#{clob_url()}/midpoint", token_id: token_id)
  end

  @doc "Batch get midpoints for multiple tokens."
  def get_midpoints(token_ids) when is_list(token_ids) do
    Req.post("#{clob_url()}/midpoints",
      json: token_ids,
      headers: [{"content-type", "application/json"}],
      receive_timeout: 10_000
    )
    |> handle()
  end

  @doc "Get orderbook for a token."
  def get_book(token_id) do
    get("#{clob_url()}/book", token_id: token_id)
  end

  @doc "Get price history for a market."
  def get_price_history(token_id, opts \\ []) do
    params = [
      market: token_id,
      interval: Keyword.get(opts, :interval, "1d"),
      fidelity: Keyword.get(opts, :fidelity, 60)
    ]

    get("#{clob_url()}/prices-history", params)
  end

  defp get(url, params) do
    Req.get(url, params: params, receive_timeout: 10_000) |> handle()
  end

  defp handle({:ok, %{status: s, body: body}}) when s in 200..299, do: {:ok, body}
  defp handle({:ok, %{body: body}}), do: {:error, body}
  defp handle({:error, reason}), do: {:error, reason}
end
