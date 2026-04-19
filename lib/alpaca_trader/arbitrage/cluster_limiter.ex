defmodule AlpacaTrader.Arbitrage.ClusterLimiter do
  @moduledoc """
  Prevent concentrating the book in a cluster of correlated pairs.

  A whitelist that passes walk-forward on 20 pairs can happily be 8 tech,
  6 energy, 4 finance, 2 crypto — one regime shock to tech and half the
  book drops in lockstep. This module treats correlated symbols as a
  single cluster and caps the number of concurrent positions per cluster.

  Clustering uses a single-linkage transitive closure on Pearson
  correlation of recent return series. `correlation_threshold` controls
  how tight a cluster is. Pure functional; callers supply the return
  series (usually from `BarsStore`) and the list of currently-open
  positions.
  """

  @doc "Pairwise Pearson correlation matrix from `symbol => series`."
  def correlation_matrix(series_map) when is_map(series_map) do
    symbols = Map.keys(series_map)

    for a <- symbols, b <- symbols, into: %{} do
      val =
        if a == b do
          1.0
        else
          pearson(Map.fetch!(series_map, a), Map.fetch!(series_map, b))
        end

      {{a, b}, val}
    end
  end

  @doc """
  Return a list of clusters (each a list of symbols). Two symbols are in
  the same cluster if their correlation >= threshold (via transitive
  closure).
  """
  def find_clusters(series_map, opts \\ []) do
    threshold = Keyword.get(opts, :correlation_threshold, 0.8)
    corr = correlation_matrix(series_map)

    adj =
      for {{a, b}, v} <- corr, a != b, v >= threshold, reduce: %{} do
        acc ->
          Map.update(acc, a, MapSet.new([b]), &MapSet.put(&1, b))
      end

    symbols = Map.keys(series_map)
    union_find_clusters(symbols, adj)
  end

  @doc """
  Decide whether opening a new pair would push a cluster past its cap.

  Options:
  - `:series` — map of symbol -> return series for clustering
  - `:correlation_threshold` (default 0.8)
  - `:max_per_cluster` (default 3)
  """
  def allow_entry?(arb, open_positions, opts) when is_map(arb) and is_list(open_positions) do
    series = Keyword.fetch!(opts, :series)
    threshold = Keyword.get(opts, :correlation_threshold, 0.8)
    max_per = Keyword.get(opts, :max_per_cluster, 3)

    clusters = find_clusters(series, correlation_threshold: threshold)

    cluster_of =
      for cluster <- clusters, sym <- cluster, into: %{}, do: {sym, MapSet.new(cluster)}

    new_symbols = [arb.asset_a, arb.asset_b]

    Enum.find_value(new_symbols, :ok, fn sym ->
      cluster = Map.get(cluster_of, sym, MapSet.new([sym]))

      count =
        Enum.count(open_positions, fn p ->
          legs = [Map.get(p, :asset_a), Map.get(p, :asset_b)] |> Enum.reject(&is_nil/1)
          Enum.any?(legs, fn s -> MapSet.member?(cluster, s) end)
        end)

      if count >= max_per do
        {:blocked, {:cluster_full, cluster |> MapSet.to_list() |> Enum.sort()}}
      else
        nil
      end
    end)
  end

  # ── helpers ────────────────────────────────────────────────

  defp pearson(xs, ys) when length(xs) == length(ys) and length(xs) > 1 do
    n = length(xs)
    mean_x = Enum.sum(xs) / n
    mean_y = Enum.sum(ys) / n

    {sxx, syy, sxy} =
      Enum.zip(xs, ys)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {a, b, c} ->
        dx = x - mean_x
        dy = y - mean_y
        {a + dx * dx, b + dy * dy, c + dx * dy}
      end)

    denom = :math.sqrt(sxx * syy)
    if denom == 0.0, do: 0.0, else: sxy / denom
  end

  defp pearson(_, _), do: 0.0

  defp union_find_clusters(symbols, adj) do
    {clusters, _visited} =
      Enum.reduce(symbols, {[], MapSet.new()}, fn sym, {acc, visited} ->
        if MapSet.member?(visited, sym) do
          {acc, visited}
        else
          cluster = bfs(sym, adj, MapSet.new([sym]))
          {[MapSet.to_list(cluster) | acc], MapSet.union(visited, cluster)}
        end
      end)

    clusters
  end

  defp bfs(_sym, adj, visited) do
    Enum.reduce_while(Stream.cycle([:continue]), visited, fn _, current ->
      new_members =
        for sym <- current,
            neighbor <- Map.get(adj, sym, MapSet.new()),
            not MapSet.member?(current, neighbor),
            reduce: current do
          acc -> MapSet.put(acc, neighbor)
        end

      if MapSet.equal?(new_members, current) do
        {:halt, current}
      else
        {:cont, new_members}
      end
    end)
  end
end
