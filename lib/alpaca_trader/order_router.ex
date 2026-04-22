defmodule AlpacaTrader.OrderRouter do
  @moduledoc """
  Central policy choke-point. Every signal passes through:
    ttl → kill_switch → capabilities → portfolio → gain → llm → submit.

  Atomic signals submit all legs concurrently; on partial fill, filled
  legs are reversed with opposite-side market orders.
  """
  alias AlpacaTrader.Types.{Signal, Leg, Order}
  alias AlpacaTrader.Broker

  require Logger

  @type outcome ::
          {:ok, [Order.t()]}
          | {:dropped, atom}
          | {:rejected, term}
          | {:atomic_break, [Order.t()]}

  @spec route(Signal.t()) :: outcome()
  def route(%Signal{} = sig) do
    with :ok <- gate_ttl(sig),
         :ok <- gate_kill_switch(sig),
         :ok <- gate_llm(sig),
         :ok <- gate_capabilities(sig),
         :ok <- gate_portfolio(sig),
         :ok <- gate_gain(sig) do
      submit(sig)
    else
      {:dropped, reason} ->
        log_outcome(sig, :dropped, reason)
        {:dropped, reason}

      {:rejected, reason} ->
        log_outcome(sig, :rejected, reason)
        {:rejected, reason}
    end
  end

  # ── gates ──────────────────────────────────────────

  defp gate_ttl(sig), do: if(Signal.expired?(sig), do: {:dropped, :expired}, else: :ok)

  defp gate_kill_switch(_sig) do
    if Application.get_env(:alpaca_trader, :trading_enabled, true),
      do: :ok,
      else: {:dropped, :kill_switch}
  end

  defp gate_llm(%Signal{conviction: c}) when is_number(c) and c >= 0.6, do: :ok
  defp gate_llm(_), do: {:dropped, :low_conviction}

  defp gate_capabilities(%Signal{legs: legs, atomic: atomic}) do
    incompatible =
      Enum.filter(legs, fn %Leg{venue: v, side: side} ->
        caps = Broker.impl(v).capabilities()
        side == :sell and !caps.shorting
      end)

    cond do
      incompatible == [] -> :ok
      atomic -> {:rejected, :venue_cannot_short}
      true -> :ok
    end
  end

  defp gate_portfolio(sig) do
    if function_exported?(AlpacaTrader.PortfolioRisk, :allow_entry_for_signal, 1) do
      case AlpacaTrader.PortfolioRisk.allow_entry_for_signal(sig) do
        :ok -> :ok
        {:blocked, reason} -> {:rejected, {:portfolio, reason}}
      end
    else
      :ok
    end
  end

  defp gate_gain(_sig) do
    case primary_equity() do
      {:ok, equity} ->
        if AlpacaTrader.GainAccumulatorStore.allow_entry?(equity),
          do: :ok,
          else: {:rejected, :gain_accumulator}

      _ ->
        :ok
    end
  end

  defp primary_equity do
    primary = Application.get_env(:alpaca_trader, :primary_equity_venue, :alpaca)
    case Broker.impl(primary).account() do
      {:ok, %{equity: eq}} when not is_nil(eq) -> {:ok, eq}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # ── submission ─────────────────────────────────────

  defp submit(%Signal{legs: legs, atomic: true} = sig) do
    results =
      legs
      |> Task.async_stream(&submit_leg/1, ordered: true, timeout: 10_000,
                            on_timeout: :kill_task,
                            max_concurrency: max(length(legs), 1))
      |> Enum.map(fn {:ok, r} -> r end)

    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {oks, []} ->
        orders = Enum.map(oks, fn {:ok, o} -> o end)
        log_outcome(sig, :submit, %{orders: order_view(orders)})
        {:ok, orders}

      {oks, _fails} ->
        filled = Enum.map(oks, fn {:ok, o} -> o end)
        Enum.each(filled, &reverse_leg/1)
        Logger.warning("[Router] atomic-break rollback: sig=#{sig.id}, filled=#{length(filled)}")
        log_outcome(sig, :atomic_break, %{filled: order_view(filled)})
        {:atomic_break, filled}
    end
  end

  defp submit(%Signal{legs: legs, atomic: false} = sig) do
    orders =
      legs
      |> Enum.map(&submit_leg/1)
      |> Enum.flat_map(fn
        {:ok, o} -> [o]
        _ -> []
      end)

    log_outcome(sig, :submit, %{orders: order_view(orders)})
    {:ok, orders}
  end

  defp submit_leg(%Leg{venue: v} = leg) do
    order = leg_to_order(leg)
    Broker.impl(v).submit_order(order, [])
  end

  defp reverse_leg(%Order{side: :buy} = o) do
    reverse = %{o | side: :sell, id: nil, status: :pending}
    Broker.impl(o.venue).submit_order(reverse, reduce_only: true)
  end

  defp reverse_leg(%Order{side: :sell} = o) do
    reverse = %{o | side: :buy, id: nil, status: :pending}
    Broker.impl(o.venue).submit_order(reverse, reduce_only: true)
  end

  defp leg_to_order(%Leg{} = l) do
    Order.new(
      venue: l.venue,
      symbol: l.symbol,
      side: l.side,
      type: l.type,
      size: to_decimal(l.size),
      size_mode: l.size_mode,
      limit_price: l.limit_price
    )
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)

  # ── shadow log ─────────────────────────────────────

  defp log_outcome(sig, type, extra \\ %{}) do
    extra_map = if is_map(extra), do: extra, else: %{gate_reason: inspect(extra)}

    payload =
      Map.merge(%{
        type: to_string(type),
        sig_id: sig.id,
        strategy: sig.strategy,
        conviction: sig.conviction,
        reason: sig.reason,
        legs: leg_view(sig.legs)
      }, normalize(extra_map))

    safe_record(payload)
  end

  defp leg_view(legs), do: Enum.map(legs, &Map.from_struct/1)

  defp order_view(orders) do
    Enum.map(orders, fn o ->
      %{venue: o.venue, symbol: o.symbol, side: o.side, status: o.status, id: o.id}
    end)
  end

  defp normalize(map) when is_map(map) do
    Enum.into(map, %{}, fn
      {k, v} when is_atom(v) -> {k, v}
      {k, v} when is_binary(v) -> {k, v}
      {k, v} when is_list(v) -> {k, v}
      {k, v} -> {k, inspect(v)}
    end)
  end

  defp safe_record(payload) do
    if function_exported?(AlpacaTrader.ShadowLogger, :record_signal, 1) do
      AlpacaTrader.ShadowLogger.record_signal(payload)
    end
  rescue
    _ -> :ok
  end
end
