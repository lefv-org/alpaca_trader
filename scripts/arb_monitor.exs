alias AlpacaTrader.Alpaca.Client
alias AlpacaTrader.Engine
alias AlpacaTrader.Engine.MarketContext
alias AlpacaTrader.AssetStore
alias AlpacaTrader.BarsStore
alias AlpacaTrader.PairPositionStore
alias AlpacaTrader.Arbitrage.{AssetRelationships, SpreadCalculator}
alias AlpacaTrader.Scheduler.Jobs.AssetSyncJob

output_file = "arb_results.log"
File.write!(output_file, "")
iterations = 30

# Initial setup
IO.puts("Syncing assets...")
{:ok, asset_count} = AssetSyncJob.run()
IO.puts("#{asset_count} assets loaded")

# Fetch bars once (daily data doesn't change between 1-min scans)
IO.puts("Fetching historical bars...")
symbols = AssetRelationships.all_symbols()
equity_syms = Enum.reject(symbols, &String.contains?(&1, "/"))
crypto_syms = Enum.filter(symbols, &String.contains?(&1, "/"))

bars = %{}
bars = case Client.get_stock_bars(equity_syms) do
  {:ok, %{"bars" => data}} when is_map(data) -> Map.merge(bars, data)
  _ -> bars
end
bars = case Client.get_crypto_bars(crypto_syms) do
  {:ok, %{"bars" => data}} when is_map(data) -> Map.merge(bars, data)
  _ -> bars
end
BarsStore.put_all_bars(bars)
IO.puts("Bars loaded for #{BarsStore.count()} symbols")

# Clear any stale positions
PairPositionStore.clear()

log = fn text ->
  line = "#{DateTime.utc_now() |> DateTime.to_iso8601()} | #{text}"
  File.write!(output_file, line <> "\n", [:append])
  IO.puts(line)
end

# Record starting equity for delta calculation
{:ok, start_account} = Client.get_account()
start_equity = start_account["equity"] |> to_string() |> Float.parse() |> elem(0)

log.("═══ ARBITRAGE MONITOR STARTED (#{iterations} iterations, 60s interval) ═══")
log.("Starting equity: $#{Float.round(start_equity, 2)}")
log.("Assets: #{asset_count} | Bars: #{BarsStore.count()} symbols | Pairs: #{length(AssetRelationships.substitute_pairs())} sub + #{length(AssetRelationships.complement_pairs())} comp")

for i <- 1..iterations do
  log.("")
  log.("─── SCAN #{i}/#{iterations} ───")

  # Fetch fresh quotes each iteration
  {:ok, account} = Client.get_account()
  {:ok, clock} = Client.get_clock()
  {:ok, positions} = Client.list_positions()
  {:ok, orders} = Client.list_orders(%{status: "all", limit: 50})

  crypto_assets = AssetStore.all() |> Enum.filter(&(&1["class"] == "crypto")) |> Enum.map(&(&1["symbol"]))
  snapshots =
    crypto_assets
    |> Enum.chunk_every(50)
    |> Enum.reduce(%{}, fn chunk, acc ->
      case Client.get_crypto_snapshots(chunk) do
        {:ok, %{"snapshots" => data}} -> Map.merge(acc, data)
        _ -> acc
      end
    end)

  ctx = %MarketContext{
    symbol: nil, account: account, position: nil, clock: clock,
    asset: nil, bars: nil, positions: positions, orders: orders, quotes: snapshots, prices: snapshots
  }

  discovery_count = AlpacaTrader.Arbitrage.DiscoveryScanner.scanned_count()
  dynamic_pairs = AlpacaTrader.Arbitrage.PairBuilder.pair_count()

  cash = account["cash"] || "?"
  equity = account["equity"] || "?"
  buying_power = account["buying_power"] || "?"
  portfolio_value = account["portfolio_value"] || equity
  unrealized_pl = account["unrealized_pl"] || "?"

  log.("┌─────────────────────────────────────────────────")
  log.("│ PORTFOLIO: equity=$#{equity}  cash=$#{cash}")
  log.("│ buying_power=$#{buying_power}  unrealized_P&L=$#{unrealized_pl}")
  log.("│ Alpaca positions: #{length(positions)}  |  Pair positions: #{PairPositionStore.open_count()}")
  log.("│ Market: #{if clock["is_open"], do: "OPEN", else: "CLOSED"}  |  Quotes: #{map_size(snapshots)}  |  Dynamic pairs: #{dynamic_pairs}")
  log.("│ Discovery: #{discovery_count}/#{AssetStore.count()} assets scanned")
  log.("└─────────────────────────────────────────────────")

  # Show open position status
  for pos <- PairPositionStore.open_positions() do
    log.("  TRACKING: #{pos.asset_a}↔#{pos.asset_b} bars=#{pos.bars_held}/#{pos.max_hold_bars} z=#{pos.current_z_score}")
  end

  # Run dry scan
  # LIVE EXECUTION — real trades on paper account
  {:ok, result} = Engine.scan_and_execute(ctx)
  log.("Scanned: #{result.scanned} | Hits: #{result.hits} | Executed: #{result.executed}")

  # Log all opportunities
  for opp <- result.opportunities do
    action_str = case opp.action do
      :enter -> "ENTER"
      :exit -> "EXIT"
      _ -> "???"
    end
    log.("  #{action_str} [Tier #{opp.tier}] #{opp.asset} — #{opp.reason}")
    if opp.pair_asset, do: log.("    Pair: #{opp.pair_asset} dir=#{opp.direction} hedge=#{opp.hedge_ratio}")
  end

  # Log z-scores for all pairs
  all_pairs = (AssetRelationships.substitute_pairs() ++ AssetRelationships.complement_pairs()) |> Enum.uniq()
  for {a, b} <- all_pairs do
    with {:ok, ca} <- BarsStore.get_closes(a),
         {:ok, cb} <- BarsStore.get_closes(b) do
      len = min(length(ca), length(cb))
      if len >= 20 do
        r = SpreadCalculator.analyze(Enum.take(ca, -len), Enum.take(cb, -len))
        if r do
          flag = cond do
            abs(r.z_score) > 4.0 -> "STOP_LOSS"
            abs(r.z_score) > 2.5 -> "TIER3_TRIGGER"
            abs(r.z_score) > 2.0 -> "TIER2_TRIGGER"
            abs(r.z_score) > 1.5 -> "APPROACHING"
            abs(r.z_score) < 0.5 -> "MEAN_ZONE"
            true -> "NORMAL"
          end
          log.("  Z: #{String.pad_trailing(a, 10)}↔#{String.pad_trailing(b, 10)} z=#{String.pad_leading("#{r.z_score}", 8)} [#{flag}]")
        end
      end
    end
  end

  # Log executed trades (scan_and_execute already executed them)
  for trade <- result.trades do
    emoji = case trade.action do
      :bought -> "🟢 BOUGHT"
      :sold -> "🔴 SOLD"
      :hold -> "⏸  HELD"
    end
    log.("  #{emoji} #{trade.symbol} qty=#{trade.qty || "-"} #{trade.reason}")
    if trade.order, do: log.("    order_id=#{trade.order["id"]} status=#{trade.order["status"]}")
  end

  if i < iterations do
    IO.puts("  ... sleeping 60s ...")
    Process.sleep(60_000)
  end
end

{:ok, end_account} = Client.get_account()
end_equity = end_account["equity"] |> to_string() |> Float.parse() |> elem(0)
delta = end_equity - start_equity
delta_pct = delta / start_equity * 100

log.("")
log.("═══════════════════════════════════════════════════")
log.("  MONITOR COMPLETE")
log.("═══════════════════════════════════════════════════")
log.("")
log.("┌─ PORTFOLIO SUMMARY ─────────────────────────────")
log.("│ Starting equity:   $#{Float.round(start_equity, 2)}")
log.("│ Ending equity:     $#{Float.round(end_equity, 2)}")
log.("│ Change:            $#{Float.round(delta, 2)} (#{Float.round(delta_pct, 4)}%)")
log.("│ Cash:              $#{end_account["cash"]}")
log.("│ Buying power:      $#{end_account["buying_power"]}")
log.("│ Unrealized P&L:    $#{end_account["unrealized_pl"]}")
log.("│")
log.("│ Alpaca positions:  #{length(end_account["portfolio_value"] || [])}")
log.("│ Pair positions:    #{PairPositionStore.open_count()}")
log.("│ Dynamic pairs:     #{AlpacaTrader.Arbitrage.PairBuilder.pair_count()}")
log.("│ Assets discovered: #{AlpacaTrader.Arbitrage.DiscoveryScanner.scanned_count()}")
log.("└─────────────────────────────────────────────────")
log.("")
for pos <- PairPositionStore.open_positions() |> Enum.take(20) do
  log.("  #{pos.asset_a}↔#{pos.asset_b} bars=#{pos.bars_held} z=#{pos.current_z_score}")
end
if PairPositionStore.open_count() > 20 do
  log.("  ... and #{PairPositionStore.open_count() - 20} more")
end
