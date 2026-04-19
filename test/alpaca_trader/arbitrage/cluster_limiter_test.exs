defmodule AlpacaTrader.Arbitrage.ClusterLimiterTest do
  use ExUnit.Case, async: true

  alias AlpacaTrader.Arbitrage.ClusterLimiter

  describe "correlation_matrix/1" do
    test "returns 1.0 on the diagonal" do
      series = %{
        "A" => [1.0, 2.0, 3.0, 4.0, 5.0],
        "B" => [5.0, 4.0, 3.0, 2.0, 1.0]
      }

      m = ClusterLimiter.correlation_matrix(series)
      assert_in_delta Map.fetch!(m, {"A", "A"}), 1.0, 1.0e-9
      assert_in_delta Map.fetch!(m, {"B", "B"}), 1.0, 1.0e-9
      assert_in_delta Map.fetch!(m, {"A", "B"}), -1.0, 1.0e-9
    end
  end

  describe "find_clusters/2" do
    test "groups symbols whose pairwise correlation exceeds threshold" do
      # A, B, C all perfectly correlated; D anticorrelated
      series = %{
        "A" => [1.0, 2.0, 3.0, 4.0, 5.0],
        "B" => [2.0, 4.0, 6.0, 8.0, 10.0],
        "C" => [3.0, 6.0, 9.0, 12.0, 15.0],
        "D" => [5.0, 4.0, 3.0, 2.0, 1.0]
      }

      clusters = ClusterLimiter.find_clusters(series, correlation_threshold: 0.9)

      assert Enum.any?(clusters, fn c -> MapSet.new(c) == MapSet.new(["A", "B", "C"]) end)
      assert Enum.any?(clusters, fn c -> MapSet.new(c) == MapSet.new(["D"]) end)
    end
  end

  describe "allow_entry?/3" do
    test "allows when no cluster is near the cap" do
      series = %{"A" => [1.0, 2.0, 3.0], "B" => [3.0, 2.0, 1.0]}
      open_positions = []

      assert :ok =
               ClusterLimiter.allow_entry?(
                 %{asset_a: "A", asset_b: "B"},
                 open_positions,
                 series: series,
                 correlation_threshold: 0.95,
                 max_per_cluster: 3
               )
    end

    test "blocks when the new pair's cluster already has max_per_cluster members" do
      series = %{
        "A" => [1.0, 2.0, 3.0, 4.0],
        "B" => [1.0, 2.0, 3.0, 4.0],
        "C" => [1.0, 2.0, 3.0, 4.0],
        "X" => [1.0, 2.0, 3.0, 4.0]
      }

      open = [
        %{asset_a: "A", asset_b: "B"},
        %{asset_a: "B", asset_b: "C"},
        %{asset_a: "A", asset_b: "C"}
      ]

      assert {:blocked, {:cluster_full, _}} =
               ClusterLimiter.allow_entry?(
                 %{asset_a: "A", asset_b: "X"},
                 open,
                 series: series,
                 correlation_threshold: 0.9,
                 max_per_cluster: 3
               )
    end

    test "counts positions, not legs, against max_per_cluster (regression)" do
      # A and B are perfectly correlated — same cluster.
      series = %{
        "A" => [1.0, 2.0, 3.0, 4.0],
        "B" => [1.0, 2.0, 3.0, 4.0],
        "C" => [10.0, 11.0, 12.0, 13.0]
      }

      # One open position; both its legs are in the A-B cluster.
      # With max_per_cluster: 2, this should count as 1 position, not 2 legs.
      open = [%{asset_a: "A", asset_b: "B"}]

      # Entering a new pair with one leg in the same cluster — count becomes 2,
      # which equals max_per_cluster; block should fire on the SECOND entry,
      # not this one.
      assert :ok =
               AlpacaTrader.Arbitrage.ClusterLimiter.allow_entry?(
                 %{asset_a: "A", asset_b: "C"},
                 open,
                 series: series,
                 correlation_threshold: 0.9,
                 max_per_cluster: 2
               )
    end

    test "blocks when positions (not legs) reach max_per_cluster" do
      series = %{
        "A" => [1.0, 2.0, 3.0, 4.0],
        "B" => [1.0, 2.0, 3.0, 4.0],
        "C" => [1.0, 2.0, 3.0, 4.0],
        "D" => [10.0, 11.0, 12.0, 13.0]
      }

      # Two open positions, each with both legs in the A-B-C cluster → count = 2.
      open = [
        %{asset_a: "A", asset_b: "B"},
        %{asset_a: "B", asset_b: "C"}
      ]

      assert {:blocked, {:cluster_full, _}} =
               AlpacaTrader.Arbitrage.ClusterLimiter.allow_entry?(
                 %{asset_a: "A", asset_b: "D"},
                 open,
                 series: series,
                 correlation_threshold: 0.9,
                 max_per_cluster: 2
               )
    end
  end
end
