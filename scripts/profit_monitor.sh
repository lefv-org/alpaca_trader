#!/usr/bin/env bash
# Local monitor for the alpaca_trader bot.
#
# Run from cron every 30 minutes during US market hours.
# Reports go to /tmp/profit-monitor.log; one-line health checks per run.
#
#   1. Verify bot + watchdog are alive. Restart if dead.
#   2. Query Alpaca paper account equity vs last_equity.
#   3. Tail recent StrategyScanJob signal counts.
#   4. Alert if equity drops >2% intraday OR no signals for >30 min.

set -u

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WATCHDOG="$REPO_DIR/scripts/bot_watchdog.sh"
BOT_LOG="/tmp/bot.log"
LOOP_LOG="/tmp/bot-loop.log"
MON_LOG="/tmp/profit-monitor.log"
STATE_FILE="/tmp/profit-monitor.state"

ts() { date -u +%FT%TZ; }
log() { echo "[$(ts)] $*" >> "$MON_LOG"; }
alert() { echo "[$(ts)] ALERT: $*" >> "$MON_LOG"; }

# Load env
set -a
[ -f "$REPO_DIR/.env" ] && . "$REPO_DIR/.env"
set +a

# 1. Bot alive check
if ! pgrep -f "beam.smp.*phx.server" >/dev/null 2>&1; then
  alert "bot process dead — restarting via watchdog"
  if pgrep -f "scripts/bot_watchdog.sh" >/dev/null 2>&1; then
    log "watchdog still running; will respawn on its own"
  else
    nohup "$WATCHDOG" >/dev/null 2>&1 &
    log "watchdog relaunched pid=$!"
  fi
  exit 0
fi

# 2. Account snapshot
if [ -z "${ALPACA_KEY_ID:-}" ] || [ -z "${ALPACA_SECRET_KEY:-}" ]; then
  alert "ALPACA_KEY_ID / ALPACA_SECRET_KEY not in .env — skipping API check"
  exit 1
fi

ACCT_JSON="$(curl -s --max-time 10 \
  -H "APCA-API-KEY-ID: $ALPACA_KEY_ID" \
  -H "APCA-API-SECRET-KEY: $ALPACA_SECRET_KEY" \
  "${ALPACA_BASE_URL:-https://paper-api.alpaca.markets}/v2/account")"

EQUITY=$(echo "$ACCT_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('equity','0'))" 2>/dev/null)
LAST_EQUITY=$(echo "$ACCT_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('last_equity','0'))" 2>/dev/null)
DT_COUNT=$(echo "$ACCT_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('daytrade_count','0'))" 2>/dev/null)

if [ -z "$EQUITY" ] || [ "$EQUITY" = "0" ]; then
  alert "account API returned no equity (auth failure?); body=$ACCT_JSON"
  exit 1
fi

# Intraday change %
PCT_CHG=$(python3 -c "
e, le = float('$EQUITY'), float('$LAST_EQUITY')
print(f'{(e-le)/le*100:.2f}' if le > 0 else '0.00')")

# 3. Recent signal activity (last 30 min)
NOW_EPOCH=$(date +%s)
CUTOFF=$((NOW_EPOCH - 1800))
RECENT_SIGNALS=$(awk -v cutoff="$CUTOFF" '
  /StrategyScanJob.*signals=/ { sigs += 1 }
  END { print sigs+0 }
' "$BOT_LOG" 2>/dev/null | tail -1)

# Total signals reported in entire log (cheap heuristic)
TOTAL_SIGNALS=$(grep -c "StrategyScanJob.*signals=[1-9]" "$BOT_LOG" 2>/dev/null | head -1)
TOTAL_SIGNALS=${TOTAL_SIGNALS:-0}

# 4. Alerts
if python3 -c "import sys; sys.exit(0 if float('$PCT_CHG') < -2.0 else 1)"; then
  alert "intraday equity drop ${PCT_CHG}% (equity=$EQUITY last=$LAST_EQUITY)"
fi

# Persist last-known signal count to detect stall
LAST_SIG_COUNT=0
if [ -f "$STATE_FILE" ]; then
  LAST_SIG_COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
fi

if [ "$TOTAL_SIGNALS" -le "$LAST_SIG_COUNT" ]; then
  STALL_RUNS_FILE="${STATE_FILE}.stall"
  STALL=$(cat "$STALL_RUNS_FILE" 2>/dev/null || echo 0)
  STALL=$((STALL + 1))
  echo "$STALL" > "$STALL_RUNS_FILE"
  if [ "$STALL" -ge 2 ]; then
    alert "no new signals in last $((STALL * 30)) min (total=$TOTAL_SIGNALS)"
  fi
else
  rm -f "${STATE_FILE}.stall"
fi
echo "$TOTAL_SIGNALS" > "$STATE_FILE"

# 5. Health one-liner
log "OK equity=\$$EQUITY (${PCT_CHG}%) dt=$DT_COUNT total_signals=$TOTAL_SIGNALS bot=alive"
