defmodule AlpacaTrader.Arbitrage.RotationEvaluator do
  @moduledoc """
  Portfolio rotation via iterative graph relaxation.

  Models the portfolio as a node in an opportunity graph. Each possible swap
  (close stale position, enter stronger signal) is a directed edge weighted by:

      edge_weight = EV(new_signal) - remaining_EV(victim) - txn_cost

  Each scan cycle relaxes the best edge (greedy single-swap). Recursive scanning
  spirals toward optimal allocation — like Bellman-Ford relaxing edges until no
  improving swap remains.

  Convergence is guaranteed: bounded positions × positive hurdle per swap.
  """

  alias AlpacaTrader.PairPositionStore.PairPosition
  alias AlpacaTrader.Arbitrage.AssetRelationships

  # Edge weights (transaction costs as friction)
  @txn_cost_per_leg 0.001
  @pair_rotation_legs 4
  @min_improvement 0.003

  @doc """
  Find the best swap in the opportunity graph for a new signal.

  Scores all open positions, finds stale candidates, picks the victim
  whose replacement yields the highest net improvement (steepest edge).

  Returns:
    {:rotate, victim_position}  — close victim, enter new signal
    :enter_normally             — no rotation needed
    :skip                       — signal doesn't justify displacing anything
  """
  def evaluate(new_signal, open_positions) when is_list(open_positions) do
    if open_positions == [] do
      :enter_normally
    else
      new_ev = signal_ev(new_signal)
      txn_cost = @txn_cost_per_leg * @pair_rotation_legs

      # Score every open position, find the steepest improving edge
      open_positions
      |> Enum.reject(&overlaps?(&1, new_signal))
      |> Enum.map(fn pos -> {pos, position_score(pos)} end)
      |> Enum.filter(fn {_pos, score} -> score.stale? end)
      |> Enum.map(fn {pos, score} ->
        {pos, new_ev - score.remaining_ev - txn_cost}
      end)
      |> Enum.filter(fn {_pos, improvement} -> improvement > @min_improvement end)
      |> Enum.max_by(fn {_pos, improvement} -> improvement end, fn -> nil end)
      |> case do
        {victim, _improvement} -> {:rotate, victim}
        nil -> :skip
      end
    end
  end

  @doc """
  Score a position's remaining expected value.

  Returns a map with:
    - convergence: 0.0 (just entered) to 1.0 (at mean)
    - time_used: fraction of max_hold_bars consumed
    - remaining_ev: estimated remaining profit as decimal (e.g., 0.012 = 1.2%)
    - stale?: whether the position is past its prime
  """
  def position_score(%PairPosition{} = pos) do
    convergence = compute_convergence(pos)
    time_used = compute_time_used(pos)
    params = AssetRelationships.params_for(pos.asset_a)

    # Remaining EV = unconverged portion × profit target
    remaining_ev = (1.0 - convergence) * (params.profit_target / 100.0)

    %{
      convergence: Float.round(convergence, 3),
      time_used: Float.round(time_used, 3),
      remaining_ev: Float.round(remaining_ev, 5),
      stale?: convergence > 0.6 and time_used > 0.5
    }
  end

  @doc """
  Expected value of a new signal, weighted by z-score strength.

  Stronger z-scores (further from mean) have higher probability of
  full convergence, so EV scales with signal magnitude.
  """
  def signal_ev(signal) do
    params = AssetRelationships.params_for(signal.asset || signal[:asset])
    z = abs(signal.z_score || signal[:z_score] || 0)

    # z=2.0 is entry threshold → strength=1.0, z=4.0 → strength=2.0 (capped)
    z_strength = min(z / 2.0, 2.0)

    params.profit_target / 100.0 * z_strength
  end

  # ── Private ──────────────────────────────────────────────────

  # How far has z reverted toward the exit threshold?
  # 0.0 = no convergence, 1.0 = fully converged to exit zone
  defp compute_convergence(%PairPosition{entry_z_score: entry_z, current_z_score: current_z, exit_z_threshold: exit_z}) do
    entry_z = entry_z || 0
    current_z = current_z || 0

    entry_distance = abs(entry_z) - exit_z
    current_distance = abs(current_z) - exit_z

    if entry_distance <= 0 do
      1.0
    else
      converged = entry_distance - max(current_distance, 0)
      (converged / entry_distance) |> max(0.0) |> min(1.0)
    end
  end

  defp compute_time_used(%PairPosition{bars_held: bars, max_hold_bars: max_bars}) do
    if max_bars > 0 do
      (bars / max_bars) |> max(0.0) |> min(1.0)
    else
      0.0
    end
  end

  # Don't rotate out of a position that shares assets with the new signal
  # (that's a flip, not a rotation)
  defp overlaps?(%PairPosition{asset_a: a, asset_b: b}, signal) do
    new_a = signal.asset || signal[:asset]
    new_b = signal.pair_asset || signal[:pair_asset]
    a == new_a or a == new_b or b == new_a or b == new_b
  end
end
