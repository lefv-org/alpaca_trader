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
iterations = 10

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

log.("═══ ARBITRAGE MONITOR STARTED (#{iterations} iterations, 60s interval) ═══")
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
    asset: nil, bars: nil, positions: positions, orders: orders, quotes: snapshots
  }

  discovery_count = AlpacaTrader.Arbitrage.DiscoveryScanner.scanned_count()
  log.("Market: open=#{clock["is_open"]} | Equity: $#{account["equity"]} | Positions: #{length(positions)} | Quotes: #{map_size(snapshots)}")
  log.("Open pair positions: #{PairPositionStore.open_count()} | Discovery progress: #{discovery_count}/#{AssetStore.count()} assets scanned")

  # Show open position status
  for pos <- PairPositionStore.open_positions() do
    log.("  TRACKING: #{pos.asset_a}↔#{pos.asset_b} bars=#{pos.bars_held}/#{pos.max_hold_bars} z=#{pos.current_z_score}")
  end

  # Run dry scan
  {:ok, result} = Engine.scan_arbitrage(ctx)
  log.("Scanned: #{result.scanned} | Hits: #{result.hits}")

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

  # Simulate what scan_and_execute would do (without actually trading)
  if result.hits > 0 do
    for opp <- result.opportunities do
      case opp.action do
        :enter ->
          log.("  → WOULD ENTER: #{opp.asset}" <> if(opp.pair_asset, do: " ↔ #{opp.pair_asset}", else: ""))
          # Actually track the position so exit logic works in subsequent scans
          if opp.tier in [2, 3] and opp.pair_asset do
            PairPositionStore.open_position(%{
              asset_a: opp.asset, asset_b: opp.pair_asset,
              direction: opp.direction, tier: opp.tier,
              z_score: opp.z_score, hedge_ratio: opp.hedge_ratio
            })
            log.("  → POSITION OPENED: #{opp.asset}↔#{opp.pair_asset}")
          end
        :exit ->
          log.("  → WOULD EXIT: #{opp.asset}" <> if(opp.pair_asset, do: " ↔ #{opp.pair_asset}", else: ""))
          pos = PairPositionStore.find_open_for_asset(opp.asset)
          if pos do
            PairPositionStore.close_position(pos.id)
            log.("  → POSITION CLOSED: #{pos.asset_a}↔#{pos.asset_b} after #{pos.bars_held} bars")
          end
        _ -> nil
      end
    end
  end

  if i < iterations do
    IO.puts("  ... sleeping 60s ...")
    Process.sleep(60_000)
  end
end

log.("")
log.("═══ MONITOR COMPLETE ═══")
log.("Final open positions: #{PairPositionStore.open_count()}")
for pos <- PairPositionStore.open_positions() do
  log.("  #{pos.asset_a}↔#{pos.asset_b} bars=#{pos.bars_held} z=#{pos.current_z_score} status=#{pos.status}")
end
