#!/usr/bin/env bash
# @description: Watch LLM opinion gate logs in real time
# @version: 1.0.0
# @group: workflows
# @shell: bash

set -euo pipefail

find_latest_output() {
    local base="/private/tmp/claude-501/-Users-home-repos-alpaca-trader"
    # Most recently modified output file = the active monitor
    find "$base" -name "*.output" -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -1
}

watch() {
    local follow="${1:-}"
    local output
    output=$(find_latest_output)
    if [ -z "$output" ]; then
        echo "No active monitor found. Start with: mcli run trade up"
        exit 1
    fi

    if [ "$follow" = "-f" ]; then
        echo "═══ LIVE TRADES ═══"
        echo "Tailing: $output"
        echo "───────────────────"
        tail -f "$output" | grep --line-buffered -E "🟢|🔴|⏸|BOUGHT|SOLD|FLIP|TAKE PROFIT|CUT LOSS|STOP LOSS|TIME EXIT|Executed|PORTFOLIO|equity"
    else
        echo "═══ LLM OPINION GATE — LIVE LOGS ═══"
        echo "Tailing: $output"
        echo "  Tip: mcli run watch_llm watch -f  (follow trades only)"
        echo "───────────────────────────────────────"
        tail -f "$output" | grep --line-buffered -i "llm gate\|CONFIRMED\|SUPPRESS\|BOUGHT\|SOLD\|polymarket\|conviction\|mlx:\|ollama:\|anthropic:"
    fi
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
    local follow="${1:-}"

    if [ "$follow" = "-f" ]; then
        local output
        output=$(find_latest_output)
        if [ -z "$output" ]; then echo "No active monitor. Start with: mcli run trade up"; exit 1; fi
        echo "═══ FOLLOWING TRADES LIVE ═══"
        echo "───────────────────────────────"
        tail -f "$output" | grep --line-buffered -E "🟢|🔴|BOUGHT|SOLD|FLIP|TAKE PROFIT|CUT LOSS|STOP LOSS|Executed|equity=|PORTFOLIO"
    else
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
        echo ""
        echo "  Tip: mcli run watch_llm trades -f  (follow live)"
    fi
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
