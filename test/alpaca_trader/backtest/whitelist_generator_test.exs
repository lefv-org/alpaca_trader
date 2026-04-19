defmodule AlpacaTrader.Backtest.WhitelistGeneratorTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.Backtest.WhitelistGenerator
  alias AlpacaTrader.Arbitrage.PairWhitelist

  setup do
    tmp =
      System.tmp_dir!() <>
        "/wl_gen_test_#{:erlang.unique_integer([:positive])}.json"

    original_path =
      Application.get_env(
        :alpaca_trader,
        :pair_whitelist_path,
        "priv/runtime/pair_whitelist.json"
      )

    Application.put_env(:alpaca_trader, :pair_whitelist_path, tmp)
    Application.put_env(:alpaca_trader, :pair_whitelist_enabled, true)
    PairWhitelist.set_path(tmp)

    on_exit(fn ->
      File.rm(tmp)
      PairWhitelist.set_path(original_path)
      Application.put_env(:alpaca_trader, :pair_whitelist_path, original_path)
      Application.put_env(:alpaca_trader, :pair_whitelist_enabled, false)
    end)

    :ok
  end

  test "selects pairs meeting the thresholds" do
    wf_result = %{
      per_pair_robustness: [
        %{
          pair: "GOOD-PAIR",
          n_windows: 3,
          wins: 3,
          win_ratio: 1.0,
          avg_window_return: 0.02,
          total_trades: 10
        },
        %{
          pair: "MEDIUM-PAIR",
          n_windows: 3,
          wins: 2,
          win_ratio: 0.67,
          avg_window_return: 0.01,
          total_trades: 5
        },
        %{
          pair: "BAD-PAIR",
          n_windows: 3,
          wins: 0,
          win_ratio: 0.0,
          avg_window_return: -0.02,
          total_trades: 4
        },
        %{
          pair: "LOW-TRADES",
          n_windows: 3,
          wins: 2,
          win_ratio: 0.67,
          avg_window_return: 0.01,
          total_trades: 2
        }
      ]
    }

    {:ok, accepted} = WhitelistGenerator.generate(wf_result, min_trades: 3)

    # GOOD and MEDIUM pass. BAD fails win_ratio+avg_return. LOW-TRADES fails min_trades.
    assert length(accepted) == 2

    pair_names =
      accepted
      |> Enum.map(fn {a, b} ->
        # Sort so comparison is canonical (PairWhitelist already normalizes)
        [a, b] |> Enum.sort() |> Enum.join("-")
      end)
      |> MapSet.new()

    assert MapSet.member?(pair_names, "GOOD-PAIR") or MapSet.member?(pair_names, "PAIR-GOOD")
  end

  test "writes through to PairWhitelist" do
    wf_result = %{
      per_pair_robustness: [
        %{
          pair: "UNI/USD-AAVE/USD",
          n_windows: 3,
          wins: 3,
          win_ratio: 1.0,
          avg_window_return: 0.015,
          total_trades: 4
        }
      ]
    }

    WhitelistGenerator.generate(wf_result)
    assert PairWhitelist.size() == 1
    assert PairWhitelist.allowed?("UNI/USD", "AAVE/USD")
  end

  test "empty input produces empty whitelist" do
    {:ok, accepted} = WhitelistGenerator.generate(%{per_pair_robustness: []})
    assert accepted == []
    assert PairWhitelist.size() == 0
  end

  test "rejects pairs below :min_net_sharpe" do
    robustness = [
      %{
        pair: "A-B",
        n_windows: 5,
        wins: 4,
        win_ratio: 0.8,
        avg_window_return: 0.01,
        total_trades: 10,
        sharpe_window_annualized: 0.5,
        per_window_returns: [0.01, 0.02, -0.01, 0.03, 0.01]
      },
      %{
        pair: "C-D",
        n_windows: 5,
        wins: 4,
        win_ratio: 0.8,
        avg_window_return: 0.01,
        total_trades: 10,
        sharpe_window_annualized: 0.1,
        per_window_returns: [0.01, 0.001, -0.005, 0.01, 0.005]
      }
    ]

    wf_result = %{per_pair_robustness: robustness}

    {:ok, accepted} =
      AlpacaTrader.Backtest.WhitelistGenerator.generate(wf_result, min_net_sharpe: 0.4)

    assert accepted == [{"A", "B"}]
  end
end
