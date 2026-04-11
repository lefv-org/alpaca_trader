defmodule AlpacaTrader.Scheduler.Api do
  @moduledoc """
  Registers job modules with the Quantum scheduler.
  """

  alias AlpacaTrader.Scheduler.Quantum, as: Q

  require Logger

  def register_job(module) do
    job_id = module.job_id()
    schedule = module.schedule()

    case Crontab.CronExpression.Parser.parse(schedule) do
      {:ok, cron} ->
        job =
          Q.new_job()
          |> Quantum.Job.set_name(String.to_atom(job_id))
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
    started = System.monotonic_time(:millisecond)

    try do
      case module.run() do
        :ok ->
          log_duration(module, started, :ok)

        {:ok, count} ->
          log_duration(module, started, {:ok, count})

        {:error, reason} ->
          log_duration(module, started, {:error, reason})
      end
    rescue
      e ->
        Logger.error("[Scheduler] #{module.job_id()} crashed: #{inspect(e)}")
        {:error, e}
    end
  end

  defp log_duration(module, started, result) do
    ms = System.monotonic_time(:millisecond) - started
    status = if match?({:error, _}, result), do: "FAILED", else: "OK"
    Logger.info("[Scheduler] #{module.job_id()} #{status} (#{ms}ms)")
    result
  end
end
