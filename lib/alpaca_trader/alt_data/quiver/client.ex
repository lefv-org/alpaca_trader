defmodule AlpacaTrader.AltData.Quiver.Client do
  @moduledoc """
  Thin Req-based client for QuiverQuant beta API.

  Honors `:quiverquant_api_key`, `:quiver_base_url`, `:quiver_timeout_ms`
  application env. Test injection via `:quiver_req_plug`.
  """

  require Logger

  @max_attempts 3
  @retry_status_set MapSet.new([429, 500, 502, 503, 504])

  @spec get(String.t(), map() | keyword()) ::
          {:ok, list() | map()} | {:error, term()}
  def get(path, params \\ %{}) do
    case Application.get_env(:alpaca_trader, :quiverquant_api_key) do
      nil -> {:error, :no_api_key}
      "" -> {:error, :no_api_key}
      key -> do_get(path, params, key, 1)
    end
  end

  defp do_get(path, params, key, attempt) do
    case Req.get(req(key), url: path, params: normalize_params(params)) do
      {:ok, %{status: s, body: body}} when s in 200..299 ->
        {:ok, body}

      {:ok, %{status: 401, body: body}} ->
        {:error, :unauthorized}
        |> tap(fn _ ->
          Logger.error("[Quiver] 401 unauthorized: #{inspect(body) |> String.slice(0..120)}")
        end)

      {:ok, %{status: 403, body: body}} ->
        {:error, :forbidden}
        |> tap(fn _ ->
          Logger.error("[Quiver] 403 forbidden: #{inspect(body) |> String.slice(0..120)}")
        end)

      {:ok, %{status: status, body: body}} ->
        if attempt < @max_attempts and MapSet.member?(@retry_status_set, status) do
          Logger.warning("[Quiver] status=#{status} attempt=#{attempt}, retrying")
          backoff(attempt)
          do_get(path, params, key, attempt + 1)
        else
          {:error, {:http_status, status, body}}
        end

      {:error, reason} ->
        if attempt < @max_attempts do
          Logger.warning("[Quiver] transport error attempt=#{attempt}: #{inspect(reason)}")
          backoff(attempt)
          do_get(path, params, key, attempt + 1)
        else
          {:error, reason}
        end
    end
  end

  defp req(key) do
    base =
      Application.get_env(:alpaca_trader, :quiver_base_url, "https://api.quiverquant.com/beta")

    timeout = Application.get_env(:alpaca_trader, :quiver_timeout_ms, 15_000)

    opts = [
      base_url: base,
      headers: [
        {"authorization", "Bearer #{key}"},
        {"accept", "application/json"}
      ],
      receive_timeout: timeout,
      connect_options: [timeout: 5_000],
      retry: false
    ]

    case Application.get_env(:alpaca_trader, :quiver_req_plug) do
      nil -> Req.new(opts)
      plug -> Req.new(Keyword.put(opts, :plug, plug))
    end
  end

  defp normalize_params(params) when is_map(params), do: Map.to_list(params)
  defp normalize_params(params) when is_list(params), do: params

  defp backoff(attempt) do
    # 500ms, 1000ms, 2000ms; tests stub Process.sleep via short timeouts.
    Process.sleep(500 * round(:math.pow(2, attempt - 1)))
  end
end
