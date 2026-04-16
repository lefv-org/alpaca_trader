defmodule AlpacaTrader.Scheduler.JobLocks do
  @moduledoc """
  Atomic per-job locks backed by an ETS table.

  Used by `Scheduler.Api.execute_job/1` to skip overlapping ticks — if a job
  scheduled every minute takes 90s to run, the next tick's attempt is rejected
  rather than piling up behind the first.

  `:ets.insert_new/2` is atomic across schedulers, so try_lock/1 is race-free.
  """

  use GenServer

  @table :scheduler_job_locks

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Returns true if the lock was acquired, false if already held."
  def try_lock(job_id) when is_binary(job_id) do
    :ets.insert_new(@table, {job_id, System.monotonic_time(:millisecond)})
  end

  def unlock(job_id) when is_binary(job_id) do
    :ets.delete(@table, job_id)
    :ok
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end
end
