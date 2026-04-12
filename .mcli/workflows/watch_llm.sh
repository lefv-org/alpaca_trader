#!/usr/bin/env bash
# @description: Watch LLM opinion gate logs in real time
# @version: 1.0.0
# @group: workflows
# @shell: bash

set -euo pipefail

find_latest_output() {
    local base="/private/tmp/claude-501/-Users-home-repos-alpaca-trader"
    # Find the largest .output file (the active monitor produces the most output)
    find "$base" -name "*.output" -type f -size +1k 2>/dev/null | xargs ls -t 2>/dev/null | head -1
}

watch() {
    echo "═══ LLM OPINION GATE — LIVE LOGS ═══"
    local output
    output=$(find_latest_output)
    if [ -z "$output" ]; then
        echo "No active monitor found. Start arb_monitor.exs first."
        exit 1
    fi
    echo "Tailing: $output"
    echo "─────────────────────────────────────"
    tail -f "$output" | grep --line-buffered -i "llm gate\|CONFIRMED\|SUPPRESS\|BOUGHT\|SOLD\|polymarket\|conviction\|mlx:\|ollama:\|anthropic:"
}

summary() {
    echo "═══ LLM GATE SUMMARY ═══"
    local output
    output=$(find_latest_output)
    if [ -z "$output" ]; then echo "No output found."; exit 1; fi

    echo "MLX confirms:      $(grep -c 'mlx: confirm' "$output" 2>/dev/null || echo 0)"
    echo "MLX suppresses:    $(grep -c 'mlx: suppress' "$output" 2>/dev/null || echo 0)"
    echo "Ollama confirms:   $(grep -c 'ollama: confirm' "$output" 2>/dev/null || echo 0)"
    echo "Ollama suppresses: $(grep -c 'ollama: suppress' "$output" 2>/dev/null || echo 0)"
    echo "Fallbacks:         $(grep -c 'LLM unavailable' "$output" 2>/dev/null || echo 0)"
    echo "Total CONFIRMED:   $(grep -c 'CONFIRMED' "$output" 2>/dev/null || echo 0)"
    echo "Total SUPPRESSED:  $(grep -c 'SUPPRESSED' "$output" 2>/dev/null || echo 0)"
    echo ""
    echo "── Conviction Distribution ──"
    grep -o 'conviction=[0-9.]*' "$output" 2>/dev/null | sort | uniq -c | sort -rn | head -10
    echo ""
    echo "── Last 10 Decisions ──"
    grep "LLM Gate.*mlx:\|LLM Gate.*ollama:\|LLM Gate.*anthropic:" "$output" 2>/dev/null | tail -10
}

trades() {
    echo "═══ EXECUTED TRADES ═══"
    local logfile="arb_results.log"

    echo "🟢 Buys:  $(grep -c '🟢' "$logfile" 2>/dev/null || echo 0)"
    echo "🔴 Sells: $(grep -c '🔴' "$logfile" 2>/dev/null || echo 0)"
    echo ""
    echo "── Executions Per Scan ──"
    grep "Executed" "$logfile" 2>/dev/null || echo "none yet"
    echo ""
    echo "── Recent Trades ──"
    grep "🟢\|🔴" "$logfile" 2>/dev/null | tail -20 || echo "none yet"
    echo ""
    echo "── Equity ──"
    grep "Starting equity" "$logfile" 2>/dev/null
    grep "PORTFOLIO" "$logfile" 2>/dev/null | tail -1
}

_list_functions() {
    echo "Available:"
    echo "  watch     — Tail LLM logs live (Ctrl+C to stop)"
    echo "  summary   — Confirm/suppress counts + conviction distribution"
    echo "  trades    — Executed buy/sell trades"
}

_main() {
    local cmd="${1:-}"
    if [ -z "$cmd" ]; then echo "Usage: mcli run watch_llm <function>"; echo ""; _list_functions; exit 0; fi
    if declare -f "$cmd" > /dev/null 2>&1; then shift; "$cmd" "$@"
    else echo "Error: Unknown '$cmd'"; _list_functions; exit 1; fi
}

_main "$@"
