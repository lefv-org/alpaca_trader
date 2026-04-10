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
end
