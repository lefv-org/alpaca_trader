defmodule AlpacaTrader.Scheduler.Jobs.ReconcileJob do
  @moduledoc """
  Runs `PositionReconciler.reconcile/0` every minute so the orphan set
  stays fresh during the trading session.

  Without periodic reconciliation, a ghost-close in PairPositionStore
  (e.g. one leg of a pair was never on Alpaca) leaves the still-held
  Alpaca asset untracked and untracked-in-orphans simultaneously,
  letting the legacy engine's `find_open_for_asset/1` return nil and
  re-buy the same asset on every signal. The PDT/orphan pre-flight
  check needs an up-to-date orphan map to actually fire.
  """
  @behaviour AlpacaTrader.Scheduler.Job

  require Logger

  @impl true
  def job_id, do: "reconcile"

  @impl true
  def job_name, do: "Position Reconciler"

  @impl true
  def schedule, do: "* * * * *"

  @impl true
  def run do
    AlpacaTrader.PositionReconciler.reconcile()
    {:ok, %{}}
  rescue
    e ->
      Logger.error("[ReconcileJob] crashed: #{Exception.message(e)}")
      {:error, e}
  end
end
