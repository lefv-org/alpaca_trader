#!/usr/bin/env bash
# Run alpaca_trader under a supervisor loop.
# Restarts the bot on crash. Logs:
#   /tmp/bot.log       — bot stdout/stderr
#   /tmp/bot-loop.log  — watchdog activity (start/exit/restart)
set -u

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG="/tmp/bot.log"
LOOP_LOG="/tmp/bot-loop.log"
SLEEP_BACKOFF=5

cd "$REPO_DIR" || exit 1

# Load .env
set -a
[ -f .env ] && . ./.env
set +a

echo "[$(date -u +%FT%TZ)] watchdog start; repo=$REPO_DIR pid=$$" >> "$LOOP_LOG"

while true; do
  echo "[$(date -u +%FT%TZ)] starting bot" >> "$LOOP_LOG"
  echo "===== boot $(date -u +%FT%TZ) =====" >> "$LOG"
  elixir --no-halt -S mix phx.server >> "$LOG" 2>&1
  rc=$?
  echo "[$(date -u +%FT%TZ)] bot exited rc=$rc, restart in ${SLEEP_BACKOFF}s" >> "$LOOP_LOG"
  sleep "$SLEEP_BACKOFF"
done
