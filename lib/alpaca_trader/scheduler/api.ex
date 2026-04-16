defmodule AlpacaTrader.Scheduler.Api do
  @moduledoc """
  Registers job modules with the Quantum scheduler.
  """

  alias AlpacaTrader.Scheduler.Quantum, as: Q
  alias AlpacaTrader.Scheduler.JobLocks

  require Logger

  def register_job(module) do
    job_id = module.job_id()
    schedule = module.schedule()

    case Crontab.CronExpression.Parser.parse(schedule) do
      {:ok, cron} ->
        # Use the job module itself as Quantum's job name. Module atoms are
        # guaranteed to already exist (the module is loaded to call .job_id()),
        # so we avoid calling String.to_atom/1 on any string input.
        job =
          Q.new_job()
          |> Quantum.Job.set_name(module)
          |> Quantum.Job.set_schedule(cron)
          |> Quantum.Job.set_task(fn -> execute_job(module) end)

        Q.add_job(job)
        Logger.info("[Scheduler] registered #{module.job_name()} (#{schedule})")
        :ok

      {:error, reason} ->
        Logger.error("[Scheduler] bad cron for #{job_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def execute_job(module) do
    job_id = module.job_id()

    if JobLocks.try_lock(job_id) do
      started = System.monotonic_time(:millisecond)

      try do
        case module.run() do
          :ok -> log_duration(module, started, :ok)
          {:ok, count} -> log_duration(module, started, {:ok, count})
          {:error, reason} -> log_duration(module, started, {:error, reason})
        end
      rescue
        e ->
          Logger.error("[Scheduler] #{job_id} crashed: #{inspect(e)}")
          {:error, e}
      after
        JobLocks.unlock(job_id)
      end
    else
      Logger.warning("[Scheduler] #{job_id} skipped — previous run still in progress")
      {:skipped, :overlap}
    end
  end

  defp log_duration(module, started, result) do
    ms = System.monotonic_time(:millisecond) - started
    status = if match?({:error, _}, result), do: "FAILED", else: "OK"
    Logger.info("[Scheduler] #{module.job_id()} #{status} (#{ms}ms)")
    result
  end
end
