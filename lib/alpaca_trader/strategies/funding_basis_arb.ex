defmodule AlpacaTrader.Strategies.FundingBasisArb do
  @moduledoc """
  Funding-rate basis arbitrage across Hyperliquid perps + Alpaca spot proxies.

  When the funding rate on a perp diverges from the carry cost of a
  correlated Alpaca proxy beyond a threshold (default 10 bps after fees),
  emit a two-leg Signal:
    - Positive funding (longs pay shorts): short perp on HL, long proxy on Alpaca
    - Negative funding: long perp on HL, short proxy on Alpaca

  Positions held until funding flips, basis converges, or 24h TTL.

  Proxy map is configured via `:asset_proxies` env. Entries with
  `quality: :none` are skipped.
  """
  @behaviour AlpacaTrader.Strategy

  alias AlpacaTrader.Types.{Signal, Leg, FeedSpec}
  alias AlpacaTrader.Broker

  # Minimum net-of-fee score in basis points to emit a signal.
  # score_bps = rate * 10_000 - fee_bps (fee_bps ≈ 2).
  # 2 bps net means raw funding >= 4 bps to trigger. Tunable per deployment.
  @threshold_bps 2
  # Nominal per-leg notional. Router resizes against buying_power in practice.
  @notional_per_leg 50.0

  @impl true
  def id, do: :funding_basis_arb

  @impl true
  def required_feeds do
    [
      %FeedSpec{venue: :hyperliquid, symbols: :whitelist, cadence: :second},
      %FeedSpec{venue: :alpaca, symbols: :whitelist, cadence: :minute}
    ]
  end

  @impl true
  def init(config) do
    {:ok, %{open_positions: %{}, config: config}}
  end

  @impl true
  def scan(state, ctx) do
    proxies = Application.get_env(:alpaca_trader, :asset_proxies, %{})

    signals =
      for {perp_sym, proxy} <- proxies,
          eligible?(proxy),
          signal = evaluate_pair(perp_sym, proxy, ctx, state),
          signal != nil,
          do: signal

    {:ok, signals, state}
  end

  @impl true
  def exits(state, _ctx) do
    # MVP: exit rules live in follow-up work. Engine/Router handles
    # forced closes via kill switch.
    {:ok, [], state}
  end

  @impl true
  def on_fill(state, fill) do
    updated =
      case fill.side do
        :buy ->
          Map.put(state.open_positions, fill.symbol, %{
            opened_at: fill.ts,
            signal_id: fill.order_id
          })

        :sell ->
          Map.delete(state.open_positions, fill.symbol)
      end

    {:ok, %{state | open_positions: updated}}
  end

  # ── helpers ────────────────────────────────────────

  defp eligible?(%{quality: :none}), do: false
  defp eligible?(%{alpaca: nil}), do: false
  defp eligible?(_), do: true

  defp evaluate_pair(perp_sym, %{alpaca: alpaca_sym}, ctx, state) do
    with false <- Map.has_key?(state.open_positions, perp_sym),
         {:ok, rate} <- fetch_funding(perp_sym),
         %{last: perp_mid} when not is_nil(perp_mid) <-
           Map.get(ctx.ticks, {:hyperliquid, perp_sym}, %{}),
         %{last: spot_mid} when not is_nil(spot_mid) <-
           Map.get(ctx.ticks, {:alpaca, alpaca_sym}, %{}) do
      basis = compute_basis(perp_mid, spot_mid)
      score_bps = Decimal.to_float(rate) * 10_000 - 2

      cond do
        score_bps > @threshold_bps ->
          build_signal(perp_sym, alpaca_sym, :positive, rate, basis)

        score_bps < -@threshold_bps ->
          build_signal(perp_sym, alpaca_sym, :negative, rate, basis)

        true ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp fetch_funding(perp_sym) do
    Broker.impl(:hyperliquid).funding_rate(perp_sym)
  rescue
    _ -> {:error, :broker_unavailable}
  end

  defp compute_basis(perp_mid, spot_mid) do
    Decimal.div(Decimal.sub(perp_mid, spot_mid), spot_mid)
  end

  defp build_signal(perp_sym, alpaca_sym, :positive, rate, basis) do
    Signal.new(
      strategy: :funding_basis_arb,
      atomic: true,
      legs: [
        %Leg{
          venue: :hyperliquid,
          symbol: perp_sym,
          side: :sell,
          size: @notional_per_leg,
          size_mode: :notional,
          type: :market
        },
        %Leg{
          venue: :alpaca,
          symbol: alpaca_sym,
          side: :buy,
          size: @notional_per_leg,
          size_mode: :notional,
          type: :market
        }
      ],
      conviction: 0.7,
      reason: "funding+#{Decimal.to_string(rate)}, basis=#{Decimal.to_string(basis)}",
      ttl_ms: 2_000,
      meta: %{funding_rate: rate, basis: basis, direction: :positive}
    )
  end

  defp build_signal(perp_sym, alpaca_sym, :negative, rate, basis) do
    Signal.new(
      strategy: :funding_basis_arb,
      atomic: true,
      legs: [
        %Leg{
          venue: :hyperliquid,
          symbol: perp_sym,
          side: :buy,
          size: @notional_per_leg,
          size_mode: :notional,
          type: :market
        },
        %Leg{
          venue: :alpaca,
          symbol: alpaca_sym,
          side: :sell,
          size: @notional_per_leg,
          size_mode: :notional,
          type: :market
        }
      ],
      conviction: 0.7,
      reason: "funding#{Decimal.to_string(rate)}, basis=#{Decimal.to_string(basis)}",
      ttl_ms: 2_000,
      meta: %{funding_rate: rate, basis: basis, direction: :negative}
    )
  end
end
