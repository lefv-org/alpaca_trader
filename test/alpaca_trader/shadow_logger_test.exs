defmodule AlpacaTrader.ShadowLoggerTest do
  use ExUnit.Case, async: false

  alias AlpacaTrader.ShadowLogger

  setup do
    # Use a per-test temp path so we don't contend with the globally-started
    # ShadowLogger in the application supervisor.
    tmp_dir = System.tmp_dir!()
    path = Path.join(tmp_dir, "shadow_signals_test_#{System.unique_integer([:positive])}.jsonl")
    File.rm_rf(path)

    pid =
      start_supervised!(
        {ShadowLogger,
         [path: path, name: :"shadow_logger_test_#{System.unique_integer([:positive])}"]}
      )

    on_exit(fn -> File.rm_rf(path) end)
    %{pid: pid, path: path}
  end

  describe "record_signal/1 + flush/0" do
    test "writes JSONL lines containing status labels on flush", %{pid: pid, path: path} do
      ts = DateTime.utc_now()

      GenServer.cast(
        pid,
        {:record,
         %{
           timestamp: ts,
           pair: "AAA-BBB",
           event: :entry_signal,
           status: :would_enter,
           z_score: 2.1
         }}
      )

      GenServer.cast(
        pid,
        {:record,
         %{
           timestamp: ts,
           pair: "AAA-BBB",
           event: :entry_signal,
           status: :blocked,
           z_score: 2.1,
           gate_rejections: [:regime]
         }}
      )

      :ok = GenServer.call(pid, :flush)

      assert File.exists?(path)
      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 2

      parsed = Enum.map(lines, &Jason.decode!/1)
      statuses = Enum.map(parsed, &Map.get(&1, "status"))
      assert "would_enter" in statuses
      assert "blocked" in statuses

      blocked = Enum.find(parsed, &(&1["status"] == "blocked"))
      assert blocked["gate_rejections"] == ["regime"]
      assert blocked["pair"] == "AAA-BBB"
    end

    test "flush is append-only across calls", %{pid: pid, path: path} do
      ts = DateTime.utc_now()

      GenServer.cast(
        pid,
        {:record,
         %{timestamp: ts, pair: "X-Y", event: :entry_signal, status: :would_enter, z_score: 2.0}}
      )

      :ok = GenServer.call(pid, :flush)

      GenServer.cast(
        pid,
        {:record,
         %{timestamp: ts, pair: "X-Y", event: :exit_signal, status: :would_exit, z_score: 0.1}}
      )

      :ok = GenServer.call(pid, :flush)

      lines = File.read!(path) |> String.split("\n", trim: true)
      assert length(lines) == 2
    end
  end

  describe "summary/0" do
    test "returns counts keyed by status", %{pid: pid} do
      ts = DateTime.utc_now()

      GenServer.cast(
        pid,
        {:record,
         %{
           timestamp: ts,
           pair: "AAA-BBB",
           event: :entry_signal,
           status: :would_enter,
           z_score: 2.1
         }}
      )

      GenServer.cast(
        pid,
        {:record,
         %{
           timestamp: ts,
           pair: "AAA-BBB",
           event: :entry_signal,
           status: :blocked,
           z_score: 2.1,
           gate_rejections: [:regime]
         }}
      )

      GenServer.cast(
        pid,
        {:record,
         %{
           timestamp: ts,
           pair: "CCC-DDD",
           event: :entry_signal,
           status: :blocked,
           z_score: 2.4,
           gate_rejections: [:portfolio]
         }}
      )

      GenServer.cast(
        pid,
        {:record,
         %{timestamp: ts, pair: "AAA-BBB", event: :entry_signal, status: :filled, z_score: 2.1}}
      )

      summary = GenServer.call(pid, :summary)

      assert summary[:would_enter] == 1
      assert summary[:blocked] == 2
      assert summary[:filled] == 1
    end
  end
end
