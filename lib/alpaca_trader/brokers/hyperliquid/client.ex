defmodule AlpacaTrader.Brokers.Hyperliquid.Client do
  @moduledoc "Thin REST client for Hyperliquid. Mainnet/testnet via config."

  @base_url_mainnet "https://api.hyperliquid.xyz"
  @base_url_testnet "https://api.hyperliquid-testnet.xyz"
  @receive_timeout_ms 10_000
  @connect_timeout_ms 5_000

  @spec post(String.t(), map) :: {:ok, term} | {:error, term}
  def post(path, body) do
    opts = [
      base_url: base_url(),
      headers: [{"content-type", "application/json"}],
      receive_timeout: @receive_timeout_ms,
      connect_options: [timeout: @connect_timeout_ms]
    ]

    opts =
      case Application.get_env(:alpaca_trader, :hyperliquid_req_plug) do
        nil -> opts
        plug -> Keyword.put(opts, :plug, plug)
      end

    case Req.new(opts) |> Req.post(url: path, json: body) do
      {:ok, %{status: s, body: body}} when s in 200..299 -> {:ok, body}
      {:ok, %{status: s, body: body}} -> {:error, {:http, s, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp base_url do
    case Application.get_env(:alpaca_trader, :hyperliquid_env, :mainnet) do
      :testnet -> @base_url_testnet
      _ -> @base_url_mainnet
    end
  end
end
