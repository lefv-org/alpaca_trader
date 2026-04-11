defmodule AlpacaTrader.Arbitrage.BellmanFord do
  @moduledoc """
  Bellman-Ford negative-cycle detection for arbitrage.

  Builds a directed graph from crypto pair quotes where:
  - Nodes = currencies (USD, BTC, ETH, etc.)
  - Edge weights = -ln(rate * (1 - fee))
  - A negative cycle = a profitable arbitrage loop after fees
  """

  @default_fee 0.0025

  @doc """
  Detects arbitrage cycles from a map of crypto snapshots.

  Returns a list of profitable cycles:
    [%{cycle: ["USD", "BTC", "ETH", "USD"], profit_pct: 0.12, edges: [...]}]
  """
  def detect_cycles(snapshots, fee \\ @default_fee) when is_map(snapshots) do
    edges = build_edges(snapshots, fee)

    if edges == [] do
      []
    else
      nodes = edges |> Enum.flat_map(fn %{from: u, to: v} -> [u, v] end) |> Enum.uniq()
      find_all_profitable_cycles(nodes, edges)
    end
  end

  @doc """
  Checks whether a specific currency appears in any detected cycle.
  """
  def currency_in_cycles?(currency, cycles) do
    Enum.find(cycles, fn c -> currency in c.cycle end)
  end

  # Build directed edges from snapshot data.
  defp build_edges(snapshots, fee) do
    Enum.flat_map(snapshots, fn {pair, snapshot} ->
      case String.split(pair, "/") do
        [base, quote_c] ->
          quote_data = snapshot["latestQuote"] || %{}
          bid = to_float(quote_data["bp"])
          ask = to_float(quote_data["ap"])

          if bid > 0 and ask > 0 do
            [
              # Buy base: quote → base (use ask price)
              %{from: quote_c, to: base, weight: -:math.log((1.0 / ask) * (1.0 - fee)),
                rate: (1.0 / ask) * (1.0 - fee), pair: pair, side: "buy"},
              # Sell base: base → quote (use bid price)
              %{from: base, to: quote_c, weight: -:math.log(bid * (1.0 - fee)),
                rate: bid * (1.0 - fee), pair: pair, side: "sell"}
            ]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  # For a small graph (~21 nodes), enumerate all 3-node and 4-node cycles directly.
  # This is simpler and more reliable than Bellman-Ford cycle reconstruction.
  defp find_all_profitable_cycles(nodes, edges) do
    # Build adjacency map: from → [{to, edge}]
    adj =
      Enum.group_by(edges, & &1.from)
      |> Map.new(fn {k, v} -> {k, Enum.map(v, fn e -> {e.to, e} end)} end)

    # Find 3-node cycles
    three_cycles =
      for a <- nodes,
          {b, e1} <- Map.get(adj, a, []),
          {c, e2} <- Map.get(adj, b, []),
          c != a,
          {d, e3} <- Map.get(adj, c, []),
          d == a do
        cycle_edges = [e1, e2, e3]
        profit = Enum.reduce(cycle_edges, 1.0, fn e, acc -> acc * e.rate end)
        profit_pct = Float.round((profit - 1.0) * 100, 4)

        %{
          cycle: [a, b, c, a],
          profit_pct: profit_pct,
          edges: Enum.map(cycle_edges, fn e -> %{pair: e.pair, side: e.side, rate: e.rate} end)
        }
      end

    # Find 4-node cycles
    four_cycles =
      for a <- nodes,
          {b, e1} <- Map.get(adj, a, []),
          {c, e2} <- Map.get(adj, b, []),
          c != a,
          {d, e3} <- Map.get(adj, c, []),
          d != a and d != b,
          {e, e4} <- Map.get(adj, d, []),
          e == a do
        cycle_edges = [e1, e2, e3, e4]
        profit = Enum.reduce(cycle_edges, 1.0, fn e, acc -> acc * e.rate end)
        profit_pct = Float.round((profit - 1.0) * 100, 4)

        %{
          cycle: [a, b, c, d, a],
          profit_pct: profit_pct,
          edges: Enum.map(cycle_edges, fn e -> %{pair: e.pair, side: e.side, rate: e.rate} end)
        }
      end

    (three_cycles ++ four_cycles)
    |> Enum.filter(fn c -> c.profit_pct > 0 end)
    |> Enum.sort_by(fn c -> -c.profit_pct end)
    |> Enum.uniq_by(fn c -> c.cycle |> Enum.sort() end)
  end

  defp to_float(nil), do: 0.0
  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v * 1.0

  defp to_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end
