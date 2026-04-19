defmodule AlpacaTrader.BarsStoreTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.BarsStore

  setup do
    # Clear store between tests by inserting an empty map
    BarsStore.put_all_bars(%{})
    # Remove the meta key left by put_all_bars so count starts at 0
    :ets.delete(:bars_store, :__meta_last_synced_at__)
    :ets.match_delete(:bars_store, {:_, :_})
    :ok
  end

  test "starts empty" do
    assert BarsStore.count() == 0
    assert BarsStore.get("AAPL") == :error
  end

  test "put_all_bars stores bars for multiple symbols" do
    bars_map = %{
      "AAPL" => [
        %{"t" => "2026-04-10T00:00:00Z", "c" => 185.0, "o" => 183.0},
        %{"t" => "2026-04-09T00:00:00Z", "c" => 183.5, "o" => 182.0}
      ],
      "MSFT" => [
        %{"t" => "2026-04-10T00:00:00Z", "c" => 420.0, "o" => 418.0}
      ]
    }

    BarsStore.put_all_bars(bars_map)
    assert BarsStore.count() == 2
  end

  test "get returns bars by symbol" do
    bars = [%{"t" => "2026-04-10T00:00:00Z", "c" => 185.0}]
    BarsStore.put_all_bars(%{"AAPL" => bars})

    assert {:ok, ^bars} = BarsStore.get("AAPL")
    assert :error = BarsStore.get("NOPE")
  end

  test "get_closes extracts close prices sorted by timestamp ascending" do
    bars = [
      %{"t" => "2026-04-10T00:00:00Z", "c" => 185.0},
      %{"t" => "2026-04-08T00:00:00Z", "c" => 180.0},
      %{"t" => "2026-04-09T00:00:00Z", "c" => 183.0}
    ]

    BarsStore.put_all_bars(%{"AAPL" => bars})

    assert {:ok, [180.0, 183.0, 185.0]} = BarsStore.get_closes("AAPL")
  end

  test "get_closes returns :error for unknown symbol" do
    assert :error = BarsStore.get_closes("NOPE")
  end

  test "count returns number of symbols stored" do
    BarsStore.put_all_bars(%{"AAPL" => [], "MSFT" => [], "NVDA" => []})
    assert BarsStore.count() == 3
  end

  test "last_synced_at returns nil before any put" do
    assert BarsStore.last_synced_at() == nil
  end

  test "last_synced_at returns timestamp after put" do
    BarsStore.put_all_bars(%{"AAPL" => []})
    assert %DateTime{} = BarsStore.last_synced_at()
  end

  test "put_all_bars replaces all previous data" do
    BarsStore.put_all_bars(%{"AAPL" => [%{"c" => 180.0}]})
    BarsStore.put_all_bars(%{"MSFT" => [%{"c" => 420.0}]})

    assert BarsStore.count() == 1
    assert :error = BarsStore.get("AAPL")
    assert {:ok, _} = BarsStore.get("MSFT")
  end

  test "put_all_bars overwrites bars for a symbol" do
    BarsStore.put_all_bars(%{"AAPL" => [%{"c" => 180.0}]})
    BarsStore.put_all_bars(%{"AAPL" => [%{"c" => 200.0}]})

    assert {:ok, [%{"c" => 200.0}]} = BarsStore.get("AAPL")
  end

  describe "recent_returns/2" do
    test "returns [] for unknown symbol" do
      assert BarsStore.recent_returns("NOPE", 5) == []
    end

    test "returns [] when only a single close is available" do
      BarsStore.put_all_bars(%{
        "AAPL" => [%{"t" => "2026-04-10T00:00:00Z", "c" => 100.0}]
      })

      assert BarsStore.recent_returns("AAPL", 5) == []
    end

    test "computes arithmetic returns from timestamp-sorted closes" do
      BarsStore.put_all_bars(%{
        "AAPL" => [
          %{"t" => "2026-04-10T00:00:00Z", "c" => 110.0},
          %{"t" => "2026-04-08T00:00:00Z", "c" => 100.0},
          %{"t" => "2026-04-09T00:00:00Z", "c" => 105.0}
        ]
      })

      # sorted closes: [100.0, 105.0, 110.0]
      # returns: [(105-100)/100, (110-105)/105] = [0.05, ~0.047619]
      assert [r1, r2] = BarsStore.recent_returns("AAPL", 10)
      assert_in_delta r1, 0.05, 1.0e-9
      assert_in_delta r2, 5.0 / 105.0, 1.0e-9
    end

    test "truncates to the last n returns" do
      closes =
        for i <- 0..9 do
          %{
            "t" => "2026-04-#{String.pad_leading("#{i + 1}", 2, "0")}T00:00:00Z",
            "c" => 100.0 + i
          }
        end

      BarsStore.put_all_bars(%{"AAPL" => closes})

      returns = BarsStore.recent_returns("AAPL", 3)
      assert length(returns) == 3
    end
  end

  describe "recent_closes/2" do
    test "returns [] for unknown symbol" do
      assert BarsStore.recent_closes("NOPE", 5) == []
    end

    test "returns closes in timestamp-ascending order" do
      BarsStore.put_all_bars(%{
        "AAPL" => [
          %{"t" => "2026-04-10T00:00:00Z", "c" => 110.0},
          %{"t" => "2026-04-08T00:00:00Z", "c" => 100.0},
          %{"t" => "2026-04-09T00:00:00Z", "c" => 105.0}
        ]
      })

      assert BarsStore.recent_closes("AAPL", 10) == [100.0, 105.0, 110.0]
    end

    test "truncates to the last n closes" do
      closes =
        for i <- 0..9 do
          %{
            "t" => "2026-04-#{String.pad_leading("#{i + 1}", 2, "0")}T00:00:00Z",
            "c" => 100.0 + i
          }
        end

      BarsStore.put_all_bars(%{"AAPL" => closes})

      assert BarsStore.recent_closes("AAPL", 3) == [107.0, 108.0, 109.0]
    end
  end
end
