defmodule AlpacaTrader.Fees.TradingValue do
  @moduledoc """
  Fee proportional to trade value (qty * price), the most common venue
  schedule. Supports per-side rates and rebates (negative fees for
  passive maker fills).

  Defaults match Alpaca's published fee schedule as of 2025:

    * Equities: $0/trade (zero-fee venue)
    * Crypto: 25bps taker, 15bps maker (no rebate)

  Override per-instantiation via opts:

      AlpacaTrader.Fees.TradingValue.compute_fee(fill,
        taker_bps: 30.0, maker_bps: 5.0)
  """
  @behaviour AlpacaTrader.Fees.Model

  @default_taker_bps 25.0
  @default_maker_bps 15.0

  @impl true
  def compute_fee(%{qty: qty, price: price, side: side}, opts \\ []) do
    taker_bps = Keyword.get(opts, :taker_bps, @default_taker_bps)
    maker_bps = Keyword.get(opts, :maker_bps, @default_maker_bps)

    bps =
      case side do
        :buy_taker -> taker_bps
        :sell_taker -> taker_bps
        :buy_maker -> maker_bps
        :sell_maker -> maker_bps
      end

    notional = Decimal.mult(to_decimal(qty), to_decimal(price))
    rate = Decimal.from_float(bps / 10_000.0)
    Decimal.mult(notional, rate)
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
end
