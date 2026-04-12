#!/usr/bin/env bash
# @description: Start/stop the continuous arbitrage trading loop
# @version: 1.0.0
# @group: workflows
# @shell: bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PID_FILE="$SCRIPT_DIR/.trade.pid"
LOG_FILE="$SCRIPT_DIR/arb_results.log"

_load_env() {
    if [ -f "$SCRIPT_DIR/.env" ]; then
        set -a
        . "$SCRIPT_DIR/.env"
        set +a
    fi
}

up() {
    echo "═══════════════════════════════════════════════"
    echo "  ALPACA TRADER — CONTINUOUS ARBITRAGE LOOP"
    echo "═══════════════════════════════════════════════"
    echo ""
    echo "  Trading live on paper account"
    echo "  Log: $LOG_FILE"
    echo "  LLM: MLX → Ollama → Anthropic"
    echo "  Press Ctrl+C to stop"
    echo ""
    echo "═══════════════════════════════════════════════"
    echo ""

    _load_env
    cd "$SCRIPT_DIR"

    # Record PID for the stop command
    echo $$ > "$PID_FILE"

    # Trap Ctrl+C to clean up
    trap '_cleanup' INT TERM

    # Run the Phoenix server with the trading cron jobs
    # This starts all scheduled jobs: AssetSync, ArbitrageScan, BarSync, PairBuild
    exec iex -S mix phx.server
}

start() {
    echo "Starting trader in background..."

    _load_env
    cd "$SCRIPT_DIR"

    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Already running (PID $(cat "$PID_FILE"))"
        exit 1
    fi

    nohup mix phx.server > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    echo "Started (PID $!)"
    echo "Log: $LOG_FILE"
    echo "Stop with: mcli run trade stop"
}

stop() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Stopping trader (PID $pid)..."
            kill "$pid" 2>/dev/null
            # Also kill any child beam processes
            pkill -f "mix phx.server" 2>/dev/null || true
            pkill -f "beam.smp.*alpaca_trader" 2>/dev/null || true
            rm -f "$PID_FILE"
            echo "Stopped."
        else
            echo "Process $pid not running. Cleaning up."
            rm -f "$PID_FILE"
        fi
    else
        echo "No PID file found. Killing any running instances..."
        pkill -f "mix phx.server" 2>/dev/null || true
        pkill -f "beam.smp.*alpaca_trader" 2>/dev/null || true
        echo "Done."
    fi
}

status() {
    _load_env
    cd "$SCRIPT_DIR"

    echo "═══ TRADER STATUS ═══"
    echo ""

    # Check if running
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Status: RUNNING (PID $(cat "$PID_FILE"))"
    elif lsof -ti:4000 > /dev/null 2>&1; then
        echo "Status: RUNNING (port 4000 in use)"
    else
        echo "Status: STOPPED"
        return
    fi

    echo ""

    # Get account info
    mix run -e '
      alias AlpacaTrader.Alpaca.Client
      alias AlpacaTrader.PairPositionStore

      {:ok, account} = Client.get_account()
      {:ok, clock} = Client.get_clock()

      IO.puts("Market: #{if clock["is_open"], do: "OPEN", else: "CLOSED"}")
      IO.puts("Equity: $#{account["equity"]}")
      IO.puts("Cash: $#{account["cash"]}")
      IO.puts("Buying power: $#{account["buying_power"]}")
      IO.puts("Pair positions: #{PairPositionStore.open_count()}")
      IO.puts("Assets cached: #{AlpacaTrader.AssetStore.count()}")
      IO.puts("Dynamic pairs: #{AlpacaTrader.Arbitrage.PairBuilder.pair_count()}")
      IO.puts("LLM calls: #{inspect(AlpacaTrader.LLM.OpinionGate.call_count())}")
    ' 2>&1 | grep -v '^\['
}

_cleanup() {
    echo ""
    echo "Shutting down trader..."
    rm -f "$PID_FILE"
    exit 0
}

# ─── Dispatcher ───

_list_functions() {
    echo "Usage: mcli run trade <command>"
    echo ""
    echo "Commands:"
    echo "  up       — Start trading in foreground (Ctrl+C to stop)"
    echo "  start    — Start trading in background"
    echo "  stop     — Stop background trader"
    echo "  status   — Show account, positions, and system status"
}

_main() {
    local cmd="${1:-}"
    if [ -z "$cmd" ]; then _list_functions; exit 0; fi
    if declare -f "$cmd" > /dev/null 2>&1; then shift; "$cmd" "$@"
    else echo "Unknown: '$cmd'"; _list_functions; exit 1; fi
}

_main "$@"
