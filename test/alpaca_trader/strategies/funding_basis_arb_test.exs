defmodule AlpacaTrader.Strategies.FundingBasisArbTest do
  use ExUnit.Case, async: false
  import Mox
  setup :verify_on_exit!

  alias AlpacaTrader.Strategies.FundingBasisArb
  alias AlpacaTrader.BrokerMock

  setup do
    Application.put_env(:alpaca_trader, :asset_proxies, %{
      "BTC" => %{alpaca: "IBIT", beta: 1.0, quality: :high}
    })
    Application.put_env(:alpaca_trader, :brokers, [
      hyperliquid: BrokerMock,
      alpaca: AlpacaTrader.Brokers.Alpaca,
      broker_mock: BrokerMock
    ])
    on_exit(fn -> Application.delete_env(:alpaca_trader, :asset_proxies) end)
    {:ok, state} = FundingBasisArb.init(%{})
    [state: state]
  end

  test "emits Signal when positive funding above threshold", %{state: s} do
    BrokerMock |> expect(:funding_rate, fn "BTC" -> {:ok, Decimal.new("0.00050")} end)
    ctx = %{
      now: DateTime.utc_now(),
      ticks: %{
        {:hyperliquid, "BTC"} => %{last: Decimal.new("60000")},
        {:alpaca, "IBIT"} => %{last: Decimal.new("60.00")}
      }
    }
    {:ok, sigs, _} = FundingBasisArb.scan(s, ctx)
    assert length(sigs) == 1
    [sig] = sigs
    assert sig.strategy == :funding_basis_arb
    [hl, al] = sig.legs
    assert hl.venue == :hyperliquid
    assert hl.side == :sell
    assert al.venue == :alpaca
    assert al.side == :buy
  end

  test "emits reverse-direction Signal when negative funding below -threshold", %{state: s} do
    BrokerMock |> expect(:funding_rate, fn "BTC" -> {:ok, Decimal.new("-0.00050")} end)
    ctx = %{
      now: DateTime.utc_now(),
      ticks: %{
        {:hyperliquid, "BTC"} => %{last: Decimal.new("60000")},
        {:alpaca, "IBIT"} => %{last: Decimal.new("60.00")}
      }
    }
    {:ok, [sig], _} = FundingBasisArb.scan(s, ctx)
    [hl, al] = sig.legs
    assert hl.side == :buy
    assert al.side == :sell
  end

  test "no signal when funding magnitude below threshold", %{state: s} do
    BrokerMock |> expect(:funding_rate, fn "BTC" -> {:ok, Decimal.new("0.00001")} end)
    ctx = %{
      now: DateTime.utc_now(),
      ticks: %{
        {:hyperliquid, "BTC"} => %{last: Decimal.new("60000")},
        {:alpaca, "IBIT"} => %{last: Decimal.new("60.00")}
      }
    }
    {:ok, [], _} = FundingBasisArb.scan(s, ctx)
  end

  test "no signal when ticks missing", %{state: s} do
    BrokerMock |> stub(:funding_rate, fn "BTC" -> {:ok, Decimal.new("0.00050")} end)
    ctx = %{now: DateTime.utc_now(), ticks: %{}}
    {:ok, [], _} = FundingBasisArb.scan(s, ctx)
  end

  test "exits/2 empty in MVP", %{state: s} do
    assert {:ok, [], ^s} = FundingBasisArb.exits(s, %{now: DateTime.utc_now()})
  end

  test "skips symbols whose proxy quality is :none", %{state: s} do
    Application.put_env(:alpaca_trader, :asset_proxies, %{
      "HYPE" => %{alpaca: nil, beta: nil, quality: :none}
    })
    BrokerMock |> stub(:funding_rate, fn _ -> {:ok, Decimal.new("0.99")} end)
    ctx = %{now: DateTime.utc_now(), ticks: %{}}
    {:ok, [], _} = FundingBasisArb.scan(s, ctx)
  end
end
