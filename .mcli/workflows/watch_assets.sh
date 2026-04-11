#!/usr/bin/env bash
# @description: Watch the AssetSyncJob cron — displays tradeable assets from the Alpaca API
# @version: 1.0.0
# @group: workflows
# @shell: bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

_load_env() {
    if [ -f "$SCRIPT_DIR/.env" ]; then
        set -a
        . "$SCRIPT_DIR/.env"
        set +a
    fi
}

watch() {
    local interval="${1:-60}"
    echo "═══════════════════════════════════════════════════════"
    echo "  Alpaca Asset Sync Watcher (every ${interval}s)"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    _load_env

    while true; do
        cd "$SCRIPT_DIR"
        mix run -e '
            alias AlpacaTrader.AssetStore
            alias AlpacaTrader.Scheduler.Jobs.AssetSyncJob

            IO.puts("\n── #{DateTime.utc_now() |> DateTime.to_string()} ──")

            case AssetSyncJob.run() do
              {:ok, count} ->
                IO.puts("✅ Synced #{count} tradeable assets")
                IO.puts("   Last synced: #{AssetStore.last_synced_at()}")

                equities = AssetStore.all() |> Enum.filter(& &1["class"] == "us_equity")
                crypto = AssetStore.all() |> Enum.filter(& &1["class"] == "crypto")

                IO.puts("\n   📊 Equities: #{length(equities)}")
                IO.puts("   ₿  Crypto:   #{length(crypto)}")

                IO.puts("\n   ── Top 20 Equities ──")
                equities
                |> Enum.sort_by(& &1["symbol"])
                |> Enum.take(20)
                |> Enum.each(fn a ->
                  IO.puts("   #{String.pad_trailing(a["symbol"], 8)} #{a["name"]}")
                end)

                IO.puts("\n   ── All Crypto ──")
                crypto
                |> Enum.sort_by(& &1["symbol"])
                |> Enum.each(fn a ->
                  IO.puts("   #{String.pad_trailing(a["symbol"], 12)} #{a["name"]}")
                end)

              {:error, err} ->
                IO.puts("❌ Sync failed: #{inspect(err)}")
            end
        ' 2>&1 | grep -v '^\['

        echo ""
        echo "── next sync in ${interval}s (Ctrl+C to stop) ──"
        sleep "$interval"
    done
}

snapshot() {
    echo "═══════════════════════════════════════════════════════"
    echo "  Alpaca Asset Store Snapshot"
    echo "═══════════════════════════════════════════════════════"

    _load_env
    cd "$SCRIPT_DIR"

    mix run -e '
        alias AlpacaTrader.AssetStore
        alias AlpacaTrader.Scheduler.Jobs.AssetSyncJob

        # Sync first
        {:ok, count} = AssetSyncJob.run()
        IO.puts("Synced #{count} tradeable assets\n")

        all = AssetStore.all()
        by_class = Enum.group_by(all, & &1["class"])

        for {class, assets} <- Enum.sort(by_class) do
          IO.puts("── #{class} (#{length(assets)}) ──")
          assets
          |> Enum.sort_by(& &1["symbol"])
          |> Enum.each(fn a ->
            exchange = a["exchange"] || ""
            IO.puts("  #{String.pad_trailing(a["symbol"], 12)} #{String.pad_trailing(exchange, 10)} #{a["name"]}")
          end)
          IO.puts("")
        end
    ' 2>&1 | grep -v '^\['
}

count() {
    _load_env
    cd "$SCRIPT_DIR"

    mix run -e '
        alias AlpacaTrader.Scheduler.Jobs.AssetSyncJob
        alias AlpacaTrader.AssetStore

        {:ok, count} = AssetSyncJob.run()
        all = AssetStore.all()
        by_class = Enum.group_by(all, & &1["class"])

        IO.puts("Total tradeable: #{count}")
        for {class, assets} <- Enum.sort(by_class) do
          IO.puts("  #{String.pad_trailing(class, 15)} #{length(assets)}")
        end
        IO.puts("Last synced: #{AssetStore.last_synced_at()}")
    ' 2>&1 | grep -v '^\['
}

# =============================================================================
# Function Dispatcher
# =============================================================================

_list_functions() {
    echo "Available functions for 'watch_assets':"
    echo "  watch [interval]  — Poll assets on a loop (default: 60s)"
    echo "  snapshot          — One-shot: sync and list all assets by class"
    echo "  count             — One-shot: sync and show counts by asset class"
}

_main() {
    local cmd="${1:-}"

    if [ -z "$cmd" ]; then
        echo "Usage: mcli run watch_assets <function> [args...]"
        echo ""
        _list_functions
        exit 0
    fi

    if declare -f "$cmd" > /dev/null 2>&1; then
        shift
        "$cmd" "$@"
    else
        echo "Error: Unknown function '$cmd'"
        echo ""
        _list_functions
        exit 1
    fi
}

_main "$@"
