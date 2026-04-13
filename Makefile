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

# Start the Phoenix dev server, full output
dev: _kill_port
	set -a; [ -f .env ] && . ./.env; set +a; elixir --no-halt -S mix phx.server

# Start trading bot in foreground — filters to trades + LLM decisions
start: _kill_port
	@echo "══════════════════════════════════════════════"
	@echo "  ALPACA TRADER  ·  paper account"
	@echo "  trades · LLM decisions · scan results"
	@echo "  full log → arb_results.log"
	@echo "  Ctrl+C to stop"
	@echo "══════════════════════════════════════════════"
	@echo ""
	set -a; [ -f .env ] && . ./.env; set +a; \
	elixir --no-halt -S mix phx.server 2>&1 | \
	tee -a arb_results.log | \
	grep --line-buffered -E \
	  "Running AlpacaTrader|Access AlpacaTrader|\[Scheduler\]|\[LLM Gate\]|\[Trade\]|\[ArbitrageScanJob\]|\[Discovery\]|\[Polymarket\]|\[error\]|\[warning\]"

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
