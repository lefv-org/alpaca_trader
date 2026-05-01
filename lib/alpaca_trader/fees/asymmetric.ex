defmodule AlpacaTrader.Fees.Asymmetric do
  @moduledoc """
  Directional fees — separate buy/sell schedules. Useful for crypto
  venues where the quote-asset side carries different fees, or for
  modelling exchange rebate programs that asymmetrically reward one
  side. Ported from hftbacktest's `DirectionalFees`.

  Opts:

    * `buy_taker_bps`  (default 25.0)
    * `buy_maker_bps`  (default 15.0)
    * `sell_taker_bps` (default 25.0)
    * `sell_maker_bps` (default 15.0)
  """
  @behaviour AlpacaTrader.Fees.Model

  @impl true
  def compute_fee(%{qty: qty, price: price, side: side}, opts \\ []) do
    bps =
      case side do
        :buy_taker -> Keyword.get(opts, :buy_taker_bps, 25.0)
        :sell_taker -> Keyword.get(opts, :sell_taker_bps, 25.0)
        :buy_maker -> Keyword.get(opts, :buy_maker_bps, 15.0)
        :sell_maker -> Keyword.get(opts, :sell_maker_bps, 15.0)
      end

    notional = Decimal.mult(to_decimal(qty), to_decimal(price))
    rate = Decimal.from_float(bps / 10_000.0)
    Decimal.mult(notional, rate)
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
end
