defmodule AlpacaTrader.Scheduler.Jobs.PairRecointegrationJobTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.Scheduler.Jobs.PairRecointegrationJob
  alias AlpacaTrader.Arbitrage.PairWhitelist

  setup do
    # Redirect whitelist to a temp file so we don't clobber runtime state.
    tmp =
      Path.join(
        System.tmp_dir!(),
        "pair_whitelist_recointeg_#{System.unique_integer([:positive])}.json"
      )

    original_path =
      Application.get_env(
        :alpaca_trader,
        :pair_whitelist_path,
        "priv/runtime/pair_whitelist.json"
      )

    Application.put_env(:alpaca_trader, :pair_whitelist_path, tmp)
    :ok = PairWhitelist.set_path(tmp)
    :ok = PairWhitelist.replace([{"A", "B"}, {"C", "D"}])

    on_exit(fn ->
      File.rm(tmp)
      PairWhitelist.set_path(original_path)
      Application.put_env(:alpaca_trader, :pair_whitelist_path, original_path)
    end)

    %{tmp: tmp}
  end

  describe "metadata" do
    test "job_id is stable" do
      assert PairRecointegrationJob.job_id() == "pair-recointegration"
    end

    test "job_name is human-readable" do
      assert is_binary(PairRecointegrationJob.job_name())
    end

    test "schedule is a weekly cron expression" do
      assert PairRecointegrationJob.schedule() == "0 6 * * 0"
    end
  end

  describe "evaluate/2" do
    test "retains pairs that pass ADF, evicts pairs that don't" do
      # Deterministic seed so the synthetic series are reproducible.
      :rand.seed(:exsplus, {1, 2, 3})

      # "A-B" has stationary synthetic spread; "C-D" has a random walk spread.
      stationary =
        Enum.scan(1..500, 0.0, fn _, last -> 0.3 * last + :rand.normal() end)

      rw =
        Enum.scan(1..500, 0.0, fn _, last -> last + :rand.normal() end)

      bars = %{
        "A" => Enum.map(stationary, &(100.0 + &1)),
        "B" => List.duplicate(100.0, 500),
        "C" => Enum.map(rw, &(100.0 + &1)),
        "D" => List.duplicate(100.0, 500)
      }

      {:ok, report} = PairRecointegrationJob.evaluate(PairWhitelist.list(), bars)

      assert {"A", "B"} in report.retained
      assert {"C", "D"} in report.evicted
    end

    test "retains pairs with insufficient data (defer to next scan)" do
      bars = %{
        "A" => List.duplicate(100.0, 10),
        "B" => List.duplicate(100.0, 10)
      }

      {:ok, report} = PairRecointegrationJob.evaluate([{"A", "B"}], bars)

      assert {"A", "B"} in report.retained
      assert report.evicted == []
    end

    test "handles missing symbol bars by retaining" do
      {:ok, report} = PairRecointegrationJob.evaluate([{"X", "Y"}], %{})

      assert {"X", "Y"} in report.retained
      assert report.evicted == []
    end
  end
end
