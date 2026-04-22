defmodule AlpacaTrader.Brokers.Mock do
  @moduledoc """
  Deterministic in-memory Broker implementation for unit + integration tests.
  State held in an Agent. Call `reset/0` in setup blocks to isolate tests.

  Not part of runtime supervision — started explicitly in test_helper.
  """
  @behaviour AlpacaTrader.Broker

  alias AlpacaTrader.Types.{Order, Account, Capabilities}

  @agent __MODULE__.Agent

  def start_link do
    Agent.start_link(fn -> initial_state() end, name: @agent)
  end

  def reset, do: Agent.update(@agent, fn _ -> initial_state() end)

  def submitted_orders,
    do: Agent.get(@agent, fn s -> Enum.reverse(s.submitted) end)

  def put_account(attrs) do
    Agent.update(@agent, fn s ->
      %{s | account: %Account{
          venue: :mock,
          equity: to_dec(attrs[:equity] || "0"),
          buying_power: to_dec(attrs[:buying_power] || "0"),
          cash: to_dec(attrs[:cash] || "0")
        }}
    end)
  end

  def put_positions(list),
    do: Agent.update(@agent, fn s -> %{s | positions: list} end)

  def put_next_submit_result(result),
    do: Agent.update(@agent, fn s -> %{s | next_submit: result} end)

  @impl true
  def submit_order(%Order{} = order, _opts) do
    Agent.get_and_update(@agent, fn s ->
      case s.next_submit do
        nil ->
          filled = %{order |
            status: :filled,
            id: "mock-#{System.unique_integer([:positive])}",
            filled_size: order.size,
            avg_fill_price: Decimal.new("1")
          }
          {{:ok, filled}, %{s | submitted: [order | s.submitted]}}
        result ->
          {result, %{s | submitted: [order | s.submitted], next_submit: nil}}
      end
    end)
  end

  @impl true
  def cancel_order(_id), do: :ok

  @impl true
  def positions, do: Agent.get(@agent, fn s -> {:ok, s.positions} end)

  @impl true
  def account, do: Agent.get(@agent, fn s -> {:ok, s.account} end)

  @impl true
  def bars(_symbol, _opts), do: {:ok, []}

  @impl true
  def stream_ticks(_symbols, _subscriber), do: {:error, :not_supported}

  @impl true
  def funding_rate(_symbol), do: {:error, :not_supported}

  @impl true
  def capabilities do
    %Capabilities{
      shorting: true,
      perps: false,
      fractional: true,
      hours: :h24,
      fee_bps: 0,
      min_notional: Decimal.new(1)
    }
  end

  defp initial_state do
    %{
      submitted: [],
      positions: [],
      account: %Account{
        venue: :mock,
        equity: Decimal.new("10000"),
        buying_power: Decimal.new("10000"),
        cash: Decimal.new("10000")
      },
      next_submit: nil
    }
  end

  defp to_dec(%Decimal{} = d), do: d
  defp to_dec(n) when is_number(n), do: Decimal.from_float(n / 1)
  defp to_dec(s) when is_binary(s), do: Decimal.new(s)
end
