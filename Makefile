.PHONY: help dev setup test lint format build
.DEFAULT_GOAL := help

## help: Show this help message
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## //' | column -t -s ':'

## dev: Start the Phoenix dev server (loads .env)
## setup: Install deps and build assets (first-time)
## test: Run tests
## lint: Compile with warnings-as-errors + format check
## format: Auto-format code
## build: Build production assets

# Start the Phoenix dev server with interactive shell, loading .env
dev:
	set -a && [ -f .env ] && . ./.env && set +a && iex -S mix phx.server

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
