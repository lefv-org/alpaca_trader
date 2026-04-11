defmodule AlpacaTrader.Scheduler.Job do
  @moduledoc """
  Behaviour for scheduled jobs.
  """

  @callback job_id() :: String.t()
  @callback job_name() :: String.t()
  @callback schedule() :: String.t()
  @callback run() :: :ok | {:ok, non_neg_integer()} | {:error, any()}

  @optional_callbacks []
end
