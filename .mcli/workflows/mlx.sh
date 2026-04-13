#!/usr/bin/env bash
# @description: Start/stop the local MLX inference server (Ministral)
# @version: 1.0.0
# @group: workflows
# @shell: bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PID_FILE="$SCRIPT_DIR/.mlx.pid"
LOG_FILE="/tmp/mlx_server.log"

_load_env() {
    if [ -f "$SCRIPT_DIR/.env" ]; then
        set -a
        . "$SCRIPT_DIR/.env"
        set +a
    fi
}

_model() {
    _load_env
    echo "${LLM_MODEL:-mlx-community/Ministral-3-8B-Instruct-2512-4bit}"
}

_port() {
    _load_env
    local url="${LLM_BASE_URL:-http://localhost:8080}"
    echo "${url##*:}"
}

cmd_up() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "MLX server already running (PID $(cat "$PID_FILE"))"
        return 0
    fi
    local model; model=$(_model)
    local port; port=$(_port)
    echo "Starting MLX server: $model on port $port"
    mlx_lm.server --model "$model" --port "$port" > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    echo "PID $! — logs: $LOG_FILE"
    echo "Waiting for server..."
    for i in $(seq 1 30); do
        if curl -sf "http://localhost:$port/v1/models" > /dev/null 2>&1; then
            echo "Ready."
            return 0
        fi
        sleep 2
    done
    echo "Timed out waiting. Check logs: $LOG_FILE"
    exit 1
}

cmd_down() {
    if [ ! -f "$PID_FILE" ]; then
        echo "No PID file found."
        return 0
    fi
    local pid; pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" && echo "Stopped MLX server (PID $pid)"
    else
        echo "Process $pid not running."
    fi
    rm -f "$PID_FILE"
}

cmd_status() {
    local port; port=$(_port)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Running (PID $(cat "$PID_FILE"))"
        curl -s "http://localhost:$port/v1/models" | python3 -c "import sys,json; d=json.load(sys.stdin); [print(' •', m['id']) for m in d.get('data',[])]" 2>/dev/null || true
    else
        echo "Not running"
    fi
}

cmd_logs() {
    tail -f "$LOG_FILE"
}

case "${1:-status}" in
    up|start)   cmd_up ;;
    down|stop)  cmd_down ;;
    status)     cmd_status ;;
    logs)       cmd_logs ;;
    *)
        echo "Usage: mcli run mlx [up|down|status|logs]"
        exit 1
        ;;
esac
