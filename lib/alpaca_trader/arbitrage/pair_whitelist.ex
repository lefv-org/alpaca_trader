defmodule AlpacaTrader.Arbitrage.PairWhitelist do
  @moduledoc """
  Admission filter for pair trades based on historical robustness.

  The full pair universe contains both consistent winners and systematic
  losers. Walk-forward validation identifies which pairs are profitable
  across regimes; this module enforces "trade only those pairs."

  State: a set of allowed pairs, loaded from a JSON file on boot. The file
  is produced by `Backtest.WhitelistGenerator` from walk-forward output and
  lives at `priv/runtime/pair_whitelist.json` (gitignored — it's tuning
  state, not source code).

  Ordering is symmetric: `{A, B}` and `{B, A}` are treated as the same pair.

  Config:
  - `pair_whitelist_enabled` (default `false`) — off by default so existing
    deployments are unaffected until explicitly opted in
  - `pair_whitelist_path` (default `priv/runtime/pair_whitelist.json`)
  """

  use GenServer
  require Logger

  @default_path "priv/runtime/pair_whitelist.json"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Is this pair allowed to trade?
  Returns `true` if the whitelist is disabled or empty (permissive default),
  `false` only when the whitelist is enabled AND the pair is not on it.
  """
  def allowed?(asset_a, asset_b) when is_binary(asset_a) and is_binary(asset_b) do
    if enabled?() do
      GenServer.call(__MODULE__, {:allowed?, normalize(asset_a, asset_b)})
    else
      true
    end
  end

  @doc "Current whitelist as a list of {a, b} tuples."
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Replace the current whitelist in-memory and persist to the configured path.

  `pairs` is a list of `{a, b}` tuples or maps with `:asset_a`/`:asset_b`.
  """
  def replace(pairs) when is_list(pairs) do
    normalized = pairs |> Enum.map(&to_tuple/1) |> MapSet.new()
    GenServer.call(__MODULE__, {:replace, normalized})
  end

  @doc "Reload from disk (useful after `Backtest.WhitelistGenerator` writes)."
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc """
  Redirect the GenServer to a new file path (for tests or operator tooling).
  Loads the new path's contents immediately.
  """
  def set_path(path) when is_binary(path) do
    GenServer.call(__MODULE__, {:set_path, path})
  end

  @doc "How many pairs are currently whitelisted."
  def size, do: GenServer.call(__MODULE__, :size)

  @doc "Whether the whitelist gate is active at runtime."
  def enabled? do
    Application.get_env(:alpaca_trader, :pair_whitelist_enabled, false)
  end

  # ── GenServer callbacks ────────────────────────────────────

  @impl true
  def init(opts) do
    path = opts[:path] || Application.get_env(:alpaca_trader, :pair_whitelist_path, @default_path)
    {:ok, %{path: path, pairs: load_file(path)}}
  end

  @impl true
  def handle_call({:allowed?, pair}, _from, %{pairs: pairs} = state) do
    reply =
      cond do
        MapSet.size(pairs) == 0 -> true
        MapSet.member?(pairs, pair) -> true
        true -> false
      end

    {:reply, reply, state}
  end

  def handle_call(:list, _from, %{pairs: pairs} = state) do
    {:reply, MapSet.to_list(pairs), state}
  end

  def handle_call(:size, _from, %{pairs: pairs} = state) do
    {:reply, MapSet.size(pairs), state}
  end

  def handle_call({:replace, pairs}, _from, state) do
    persist(pairs, state.path)
    Logger.info("[PairWhitelist] replaced: #{MapSet.size(pairs)} pairs → #{state.path}")
    {:reply, :ok, %{state | pairs: pairs}}
  end

  def handle_call(:reload, _from, state) do
    pairs = load_file(state.path)
    Logger.info("[PairWhitelist] reloaded: #{MapSet.size(pairs)} pairs from #{state.path}")
    {:reply, :ok, %{state | pairs: pairs}}
  end

  def handle_call({:set_path, path}, _from, state) do
    pairs = load_file(path)
    {:reply, :ok, %{state | path: path, pairs: pairs}}
  end

  # ── Persistence ────────────────────────────────────────────

  defp load_file(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"pairs" => pairs}} when is_list(pairs) ->
            pairs
            |> Enum.map(&to_tuple/1)
            |> Enum.reject(&is_nil/1)
            |> MapSet.new()

          _ ->
            MapSet.new()
        end

      {:error, :enoent} ->
        MapSet.new()

      {:error, reason} ->
        Logger.warning("[PairWhitelist] failed to load #{path}: #{inspect(reason)}")
        MapSet.new()
    end
  end

  defp persist(pairs, path) do
    payload =
      Jason.encode!(%{
        pairs: MapSet.to_list(pairs) |> Enum.map(fn {a, b} -> %{asset_a: a, asset_b: b} end),
        updated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        count: MapSet.size(pairs)
      })

    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, payload),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.error("[PairWhitelist] failed to persist: #{inspect(reason)}")
    end
  end

  # ── Helpers ────────────────────────────────────────────────

  defp normalize(a, b) when a <= b, do: {a, b}
  defp normalize(a, b), do: {b, a}

  defp to_tuple({a, b}) when is_binary(a) and is_binary(b), do: normalize(a, b)

  defp to_tuple(%{"asset_a" => a, "asset_b" => b})
       when is_binary(a) and is_binary(b),
       do: normalize(a, b)

  defp to_tuple(%{asset_a: a, asset_b: b})
       when is_binary(a) and is_binary(b),
       do: normalize(a, b)

  defp to_tuple(_), do: nil
end
