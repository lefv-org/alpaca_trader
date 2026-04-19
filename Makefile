.PHONY: help dev dev-force start start-force setup test lint format build check-env preflight preflight-force flatten unquarantine _kill_port _unquarantine _build_mac_listener
.DEFAULT_GOAL := help

## help: Show this help message
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## //' | column -t -s ':'

## dev:          Start the Phoenix dev server, full logs → output.log (loads .env)
## dev-force:    Flatten (safe) + --allow-all preflight + start dev server
## start:        Start trading bot, foreground — shows trades + LLM decisions only
## start-force:  Flatten (safe) + --allow-all preflight + start trading bot
## setup:        Install deps and build assets (first-time)
## test:         Run tests
## lint:         Compile with warnings-as-errors + format check
## format:       Auto-format code
## build:        Build production assets
## check-env:    Verify .env.example has all keys present in .env (drift detection)
## preflight:    Pre-flight safety check (runs automatically before start)
## flatten:      Close open positions safely (PDT-aware)
## unquarantine: Strip macOS Gatekeeper quarantine from esbuild/tailwind/mac_listener binaries

# Strip macOS Gatekeeper quarantine xattr from prebuilt binaries downloaded
# by mix deps (esbuild, tailwind, mac_listener). Safe no-op on non-macOS.
# Runs silently as a dev prerequisite so Gatekeeper popups don't block boot.
_unquarantine:
	@if [ "$$(uname)" = "Darwin" ]; then \
	  xattr -dr com.apple.quarantine _build deps 2>/dev/null || true; \
	fi

# Build mac_listener (file_system/priv) so Phoenix live-reload works on macOS.
# The file_system hex package ships C source but no prebuilt macOS binary;
# the package's own compile step only runs when the source is newer than the
# target, so a fresh dep install leaves priv/mac_listener absent and emits
# "Can't find executable mac_listener" every boot.
_build_mac_listener:
	@if [ "$$(uname)" = "Darwin" ] && [ -d deps/file_system/c_src/mac ] && [ ! -f deps/file_system/priv/mac_listener ]; then \
	  echo "Building mac_listener (Phoenix live-reload)..."; \
	  xcrun -r clang -framework CoreFoundation -framework CoreServices \
	    -Wno-deprecated-declarations \
	    deps/file_system/c_src/mac/*.c \
	    -o deps/file_system/priv/mac_listener 2>/dev/null || \
	    echo "  (mac_listener build failed — live-reload will be disabled; not fatal)"; \
	fi

## unquarantine: Strip macOS Gatekeeper quarantine (manual invocation)
unquarantine: _unquarantine
	@echo "quarantine stripped from _build and deps"

# Kill whatever is on PORT (default 4000), then start
_kill_port:
	@PORT=$${PORT:-4000}; \
	pids=$$(lsof -ti:$$PORT 2>/dev/null); \
	if [ -n "$$pids" ]; then \
	  echo "Killing PID(s) $$pids on port $$PORT"; \
	  echo "$$pids" | xargs kill -9 2>/dev/null || true; \
	fi

# Print session P&L using LIVE Alpaca equity (not stale JSON snapshot).
# Falls back to cached values if the API call fails.
_session_summary = mix session_summary 2>/dev/null || true

# Start the Phoenix dev server, full output → also logs to output.log
dev: _kill_port _unquarantine _build_mac_listener preflight
	@set -a; [ -f .env ] && . ./.env; set +a; \
	trap '$(_session_summary)' INT TERM; \
	elixir --no-halt -S mix phx.server 2>&1 | tee -a output.log; \
	$(_session_summary)

# Same as dev but acknowledges all soft-blockers (small equity + PDT risk),
# AND flattens open positions first (safe mode: crypto + prior-day equity only).
# Use only when you understand the risks — one day trade on a PDT-risk account
# locks it for 90 days. Flatten runs before preflight so equity + orphan counts
# reflect the post-close state.
dev-force: _kill_port _unquarantine _build_mac_listener flatten preflight-force
	@set -a; [ -f .env ] && . ./.env; set +a; \
	trap '$(_session_summary)' INT TERM; \
	elixir --no-halt -S mix phx.server 2>&1 | tee -a output.log; \
	$(_session_summary)

# Pre-flight safety check: fails hard if PDT-locked, tiny live balance, etc.
preflight:
	@set -a; [ -f .env ] && . ./.env; set +a; mix preflight

# Pre-flight with all soft-blockers acknowledged
preflight-force:
	@set -a; [ -f .env ] && . ./.env; set +a; mix preflight --allow-all

# Close open positions (safe by default: crypto + prior-day equity only)
flatten:
	@set -a; [ -f .env ] && . ./.env; set +a; mix flatten

# Same as start but acknowledges all soft-blockers AND flattens first
start-force: _kill_port _unquarantine _build_mac_listener flatten preflight-force
	@echo "══════════════════════════════════════════════"
	@echo "  ALPACA TRADER  ·  FORCED START  ·  soft blocks ACKed"
	@echo "══════════════════════════════════════════════"
	@echo ""
	@set -a; [ -f .env ] && . ./.env; set +a; \
	trap '$(_session_summary)' INT TERM; \
	elixir --no-halt -S mix phx.server 2>&1 | \
	tee -a arb_results.log | \
	grep --line-buffered -E \
	  "Running AlpacaTrader|Access AlpacaTrader|\[Scheduler\]|\[LLM Gate\]|\[Trade\]|\[ArbitrageScanJob\]|\[Discovery\]|\[Polymarket\]|\[error\]|\[warning\]"; \
	$(_session_summary)

# Start trading bot in foreground — filters to trades + LLM decisions
start: _kill_port _unquarantine _build_mac_listener preflight
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

# Check that every key set in .env also has a placeholder in .env.example.
# Comment-only references in .env.example count as present.
check-env:
	@if [ ! -f .env ]; then echo "no .env file; skipping check"; exit 0; fi
	@missing=""; \
	for key in $$(grep -oE '^[A-Z_][A-Z0-9_]*=' .env | sed 's/=$$//' | sort -u); do \
	  if ! grep -qE "^#?\\s*$$key=" .env.example; then \
	    missing="$$missing $$key"; \
	  fi; \
	done; \
	if [ -n "$$missing" ]; then \
	  echo "missing from .env.example:$$missing"; \
	  exit 1; \
	else \
	  echo ".env.example is in sync with .env"; \
	fi
