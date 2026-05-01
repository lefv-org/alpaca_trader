defmodule AlpacaTrader.Fees.Model do
  @moduledoc """
  Pluggable fee model behaviour. Ported from hftbacktest's
  `src/backtest/models/fee.rs` — TradingValueFeeModel,
  TradingQtyFeeModel, FlatPerTradeFeeModel, DirectionalFees.

  Live runtime, backtest, and the PerformanceTracker share one fee
  calculation path so net-of-fee P&L is consistent everywhere.

  Side conventions:
    * `:buy_taker`   — aggressive buy (crosses spread)
    * `:buy_maker`   — passive buy (rests on bid)
    * `:sell_taker` — aggressive sell
    * `:sell_maker` — passive sell

  Returns fee as a Decimal in the same currency as the trade notional.
  Positive numbers are *paid by us* (deducted from P&L). Negative numbers
  are rebates.
  """

  @type side :: :buy_taker | :buy_maker | :sell_taker | :sell_maker

  @type fill :: %{
          required(:venue) => atom,
          required(:symbol) => String.t(),
          required(:side) => side,
          required(:qty) => Decimal.t() | float,
          required(:price) => Decimal.t() | float,
          optional(any) => any
        }

  @callback compute_fee(fill, opts :: keyword) :: Decimal.t()
end
