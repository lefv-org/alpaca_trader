defmodule AlpacaTrader.Brokers.Alpaca do
  @moduledoc """
  Alpaca Broker implementation. Wraps AlpacaTrader.Alpaca.Client (existing HTTP)
  and normalizes responses into %Order{}, %Position{}, %Account{}.
  """
  @behaviour AlpacaTrader.Broker

  alias AlpacaTrader.Alpaca.Client
  alias AlpacaTrader.Types.{Order, Position, Account, Bar, Capabilities}
  alias AlpacaTrader.Brokers.Alpaca.Symbol

  @impl true
  def submit_order(%Order{} = order, _opts) do
    body = to_alpaca_body(order)
    case Client.create_order(body) do
      {:ok, resp} ->
        {:ok, decode_order(resp, order)}

      {:error, %{"message" => msg}} ->
        require Logger

        Logger.warning(
          "[Broker.Alpaca] order rejected #{order.symbol} #{order.side}: #{msg} body=#{inspect(body)}"
        )

        {:ok, %{order | status: :rejected, reason: msg}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def cancel_order(id) do
    case Client.cancel_order(id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def positions do
    with {:ok, list} <- Client.list_positions() do
      {:ok, Enum.map(list, &decode_position/1)}
    end
  end

  @impl true
  def account do
    with {:ok, raw} <- Client.get_account() do
      {:ok, decode_account(raw)}
    end
  end

  @impl true
  def bars(symbol, opts) do
    params = Keyword.get(opts, :params, %{})
    is_crypto = String.contains?(symbol, "/")
    fetch =
      if is_crypto,
        do: &Client.get_crypto_bars/2,
        else: &Client.get_stock_bars/2
    case fetch.([symbol], params) do
      {:ok, %{"bars" => bars_map}} ->
        bars = Map.get(bars_map, symbol, [])
        {:ok, Enum.map(bars, &decode_bar(&1, symbol))}
      {:ok, _other} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def funding_rate(_symbol), do: {:error, :not_supported}

  @doc """
  Escape hatch for callers that still build Alpaca-native order param maps
  (engine/order_executor pre-Strategy-abstraction). Bypasses struct
  conversion and returns raw broker responses.

  Phase 3 removes this: strategies will emit `%Signal{}` → OrderRouter
  builds `%Order{}` → `submit_order/2`.
  """
  @spec submit_order_raw(map) :: {:ok, map} | {:error, term}
  def submit_order_raw(params) when is_map(params), do: Client.create_order(params)

  @impl true
  def capabilities do
    %Capabilities{
      shorting: Application.get_env(:alpaca_trader, :allow_short_selling, false),
      perps: false,
      fractional: true,
      min_notional: Decimal.new("1.00"),
      fee_bps: 0,
      hours: :rth
    }
  end

  # ── decoders ──────────────────────────────────────────────

  defp to_alpaca_body(%Order{} = o) do
    base = %{
      "symbol" => Symbol.to_alpaca(o.symbol),
      "side" => Atom.to_string(o.side),
      "type" => Atom.to_string(o.type),
      "time_in_force" => resolve_tif(o)
    }
    size = case o.size_mode do
      :qty -> %{"qty" => Decimal.to_string(o.size, :normal)}
      :notional -> %{"notional" => Decimal.to_string(Decimal.round(o.size, 2), :normal)}
      :pct_equity -> raise "pct_equity size_mode must be resolved by router before submit"
    end

    # Limit orders need a limit_price; without it Alpaca returns 422
    # "limit orders require a limit price". OBI emits limit legs from
    # check_imbalance/8, so this path was silently rejected on every
    # OBI signal.
    extras =
      case {o.type, o.limit_price} do
        {:limit, %Decimal{} = lp} -> %{"limit_price" => Decimal.to_string(lp, :normal)}
        {:limit, lp} when is_number(lp) -> %{"limit_price" => "#{lp}"}
        _ -> %{}
      end

    base
    |> Map.merge(size)
    |> Map.merge(extras)
  end

  # Alpaca rejects "day" time_in_force on crypto symbols (24/7 market —
  # must be gtc / ioc / fok). The Order struct defaults tif to :day,
  # correct for equities but wrong for any crypto routed through the
  # Strategy/OrderRouter path (strategies don't set tif explicitly).
  # The legacy OrderExecutor.resolve_time_in_force already handled this
  # for engine-emitted orders; push the same logic down into the broker
  # so every path that ends here gets a valid value.
  defp resolve_tif(%Order{tif: tif, symbol: symbol}) do
    is_crypto = is_binary(symbol) and String.contains?(symbol, "/")

    cond do
      is_crypto and tif in [nil, :day] -> "gtc"
      is_crypto -> Atom.to_string(tif)
      tif in [nil] -> "day"
      true -> Atom.to_string(tif)
    end
  end

  defp decode_order(resp, %Order{} = original) do
    %{original |
      id: resp["id"],
      status: decode_status(resp["status"]),
      submitted_at: decode_ts(resp["submitted_at"]),
      filled_size: to_dec(resp["filled_qty"] || "0"),
      avg_fill_price: resp["filled_avg_price"] && to_dec(resp["filled_avg_price"]),
      raw: resp
    }
  end

  defp decode_status("accepted"), do: :submitted
  defp decode_status("new"), do: :submitted
  defp decode_status("partially_filled"), do: :partial
  defp decode_status("filled"), do: :filled
  defp decode_status("canceled"), do: :canceled
  defp decode_status("rejected"), do: :rejected
  defp decode_status(_), do: :submitted

  defp decode_position(raw) do
    %Position{
      venue: :alpaca,
      symbol: Symbol.from_alpaca(raw["symbol"]),
      qty: to_dec(raw["qty"]),
      avg_entry: raw["avg_entry_price"] && to_dec(raw["avg_entry_price"]),
      mark: raw["current_price"] && to_dec(raw["current_price"]),
      asset_class: map_asset_class(raw["asset_class"]),
      raw: raw
    }
  end

  defp map_asset_class("us_equity"), do: :equity
  defp map_asset_class("crypto"), do: :crypto
  defp map_asset_class(_), do: :unknown

  defp decode_account(raw) do
    %Account{
      venue: :alpaca,
      equity: to_dec(raw["equity"]),
      cash: to_dec(raw["cash"]),
      buying_power: to_dec(raw["buying_power"]),
      daytrade_count: to_int(raw["daytrade_count"]),
      pattern_day_trader: raw["pattern_day_trader"] == true,
      currency: raw["currency"] || "USD",
      raw: raw
    }
  end

  defp decode_bar(bar, symbol) do
    %Bar{venue: :alpaca, symbol: symbol,
         o: to_dec(bar["o"]), h: to_dec(bar["h"]),
         l: to_dec(bar["l"]), c: to_dec(bar["c"]),
         v: to_dec(bar["v"] || "0"),
         ts: decode_ts(bar["t"]), timeframe: :minute}
  end

  defp to_dec(nil), do: Decimal.new(0)
  defp to_dec(%Decimal{} = d), do: d
  defp to_dec(n) when is_integer(n), do: Decimal.new(n)
  defp to_dec(n) when is_float(n), do: Decimal.from_float(n)
  defp to_dec(s) when is_binary(s), do: Decimal.new(s)

  defp to_int(nil), do: 0
  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: trunc(n)
  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp decode_ts(nil), do: nil
  defp decode_ts(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
