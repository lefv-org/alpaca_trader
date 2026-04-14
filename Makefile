.PHONY: help dev start setup test lint format build _kill_port
.DEFAULT_GOAL := help

## help: Show this help message
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## //' | column -t -s ':'

## dev:   Start the Phoenix dev server, full logs (loads .env)
## start: Start trading bot, foreground — shows trades + LLM decisions only
## setup: Install deps and build assets (first-time)
## test:  Run tests
## lint:  Compile with warnings-as-errors + format check
## format: Auto-format code
## build: Build production assets

# Kill whatever is on PORT (default 4000), then start
_kill_port:
	@PORT=$${PORT:-4000}; \
	pids=$$(lsof -ti:$$PORT 2>/dev/null); \
	if [ -n "$$pids" ]; then \
	  echo "Killing PID(s) $$pids on port $$PORT"; \
	  echo "$$pids" | xargs kill -9 2>/dev/null || true; \
	fi

# Print session P&L from gain accumulator JSON
_session_summary = \
	GAIN_FILE=$${GAIN_ACCUMULATOR_PATH:-priv/gain_accumulator.json}; \
	if [ -f "$$GAIN_FILE" ]; then \
	  echo ""; \
	  echo "══════════════════════════════════════════════"; \
	  echo "  SESSION SUMMARY"; \
	  echo "──────────────────────────────────────────────"; \
	  python3 -c " \
import json, sys; \
d = json.load(open('$$GAIN_FILE')); \
gain = d.get('gain', 0); \
sym = '📈' if gain >= 0 else '📉'; \
print(f\"  Principal:  \$${d['principal']:,.2f}\"); \
print(f\"  Equity:     \$${d.get('equity', d['principal']):,.2f}\"); \
print(f\"  Session P&L: {sym} \$${gain:+,.2f}\"); \
print(f\"  Account:    {d.get('account_env', 'unknown')}\"); \
" 2>/dev/null || echo "  (could not read session data)"; \
	  echo "══════════════════════════════════════════════"; \
	fi

# Start the Phoenix dev server, full output
dev: _kill_port
	@set -a; [ -f .env ] && . ./.env; set +a; \
	trap '$(_session_summary)' INT TERM; \
	elixir --no-halt -S mix phx.server; \
	$(_session_summary)

# Start trading bot in foreground — filters to trades + LLM decisions
start: _kill_port
	@echo "══════════════════════════════════════════════"
	@echo "  ALPACA TRADER  ·  paper account"
	@echo "  trades · LLM decisions · scan results"
	@echo "  full log → arb_results.log"
	@echo "  Ctrl+C to stop"
	@echo "══════════════════════════════════════════════"
	@echo ""
	@set -a; [ -f .env ] && . ./.env; set +a; \
	trap '$(_session_summary)' INT TERM; \
	elixir --no-halt -S mix phx.server 2>&1 | \
	tee -a arb_results.log | \
	grep --line-buffered -E \
	  "Running AlpacaTrader|Access AlpacaTrader|\[Scheduler\]|\[LLM Gate\]|\[Trade\]|\[ArbitrageScanJob\]|\[Discovery\]|\[Polymarket\]|\[error\]|\[warning\]"; \
	$(_session_summary)

# Install deps and build assets (first-time setup)
setup:
	mix setup

# Run tests
test:
	mix test

# Compile with warnings as errors + format check
lint:
	mix compile --warnings-as-errors
	mix format --check-formatted

# Auto-format code
format:
	mix format

# Build production assets
build:
	mix assets.deploy
