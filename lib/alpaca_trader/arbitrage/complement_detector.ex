defmodule AlpacaTrader.Arbitrage.ComplementDetector do
  @moduledoc """
  Tier 3: Complement arbitrage via mean-reversion of structurally linked pairs.
  Higher threshold than substitutes due to noisier relationships.
  """

  alias AlpacaTrader.Arbitrage.{AssetRelationships, SpreadCalculator}
  alias AlpacaTrader.BarsStore

  @z_threshold 2.5

  @doc """
  Check if the given asset has a complement arbitrage opportunity.
  Returns `{:ok, signal}` or `{:ok, nil}`.
  """
  def detect(symbol) do
    partners = AssetRelationships.complements_for(symbol)

    signal =
      partners
      |> Enum.reduce(nil, fn partner, best ->
        case compute_signal(symbol, partner) do
          nil -> best
          signal -> pick_stronger(best, signal)
        end
      end)

    {:ok, signal}
  end

  defp compute_signal(symbol_a, symbol_b) do
    with {:ok, closes_a} <- BarsStore.get_closes(symbol_a),
         {:ok, closes_b} <- BarsStore.get_closes(symbol_b) do
      len = min(length(closes_a), length(closes_b))
      a = Enum.take(closes_a, -len)
      b = Enum.take(closes_b, -len)

      case SpreadCalculator.analyze(a, b) do
        nil ->
          nil

        %{z_score: z, hedge_ratio: ratio} when abs(z) > @z_threshold ->
          direction =
            if z > 0,
              do: :long_b_short_a,
              else: :long_a_short_b

          %{
            asset_a: symbol_a,
            asset_b: symbol_b,
            z_score: z,
            hedge_ratio: ratio,
            direction: direction
          }

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp pick_stronger(nil, signal), do: signal
  defp pick_stronger(best, signal) do
    if abs(signal.z_score) > abs(best.z_score), do: signal, else: best
  end
end
