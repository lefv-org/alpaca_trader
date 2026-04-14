import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/alpaca_trader start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :alpaca_trader, AlpacaTraderWeb.Endpoint, server: true
end

config :alpaca_trader, AlpacaTraderWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :alpaca_trader, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :alpaca_trader, AlpacaTraderWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :alpaca_trader, AlpacaTraderWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :alpaca_trader, AlpacaTraderWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

if config_env() != :test do
  config :alpaca_trader,
    alpaca_base_url: System.fetch_env!("ALPACA_BASE_URL"),
    # paper:  https://paper-api.alpaca.markets
    # live:   https://api.alpaca.markets
    alpaca_key_id: System.fetch_env!("ALPACA_KEY_ID"),
    alpaca_secret_key: System.fetch_env!("ALPACA_SECRET_KEY"),
    # Order sizing and portfolio risk
    # Trade size as a fraction of equity (0.001 = 0.1% of equity per trade)
    order_notional_pct: String.to_float(System.get_env("ORDER_NOTIONAL_PCT", "0.001")),
    # Round-trip fee rate (crypto ~0.30% = 0.003, equities = 0)
    trade_fee_rate: String.to_float(System.get_env("TRADE_FEE_RATE", "0.003")),
    gain_accumulator_path: System.get_env("GAIN_ACCUMULATOR_PATH", "priv/gain_accumulator.json"),
    portfolio_reserve_pct: String.to_float(System.get_env("PORTFOLIO_RESERVE_PCT", "0.25")),
    allow_short_selling: System.get_env("ALLOW_SHORT_SELLING", "false") == "true",
    # LLM provider toggles: enable/disable each provider in the failover chain
    llm_use_mlx: System.get_env("LLM_USE_MLX", "false") == "true",
    llm_use_ollama: System.get_env("LLM_USE_OLLAMA", "false") == "true",
    llm_use_anthropic: System.get_env("LLM_USE_ANTHROPIC", "false") == "true",
    # MLX (local)
    llm_base_url: System.get_env("LLM_BASE_URL", "http://localhost:8080"),
    llm_model: System.get_env("LLM_MODEL", "mlx-community/Phi-3.5-mini-instruct-4bit"),
    # Ollama (remote)
    ollama_base_url: System.get_env("OLLAMA_BASE_URL", "https://ollama.lefv.info"),
    ollama_model: System.get_env("OLLAMA_MODEL", "qwen3:8b"),
    ollama_api_key: System.get_env("OLLAMA_API_KEY"),
    ollama_timeout_ms: String.to_integer(System.get_env("OLLAMA_TIMEOUT_MS", "30000")),
    # Cerebras (free cloud)
    llm_use_cerebras: System.get_env("LLM_USE_CEREBRAS", "false") == "true",
    cerebras_base_url: System.get_env("CEREBRAS_BASE_URL", "https://api.cerebras.ai"),
    cerebras_model: System.get_env("CEREBRAS_MODEL", "llama3.1-8b"),
    cerebras_api_key: System.get_env("CEREBRAS_API_KEY"),
    # OpenRouter (free cloud)
    llm_use_openrouter: System.get_env("LLM_USE_OPENROUTER", "false") == "true",
    openrouter_base_url: System.get_env("OPENROUTER_BASE_URL", "https://openrouter.ai/api"),
    openrouter_model: System.get_env("OPENROUTER_MODEL", "meta-llama/llama-3.3-70b-instruct:free"),
    openrouter_api_key: System.get_env("OPENROUTER_API_KEY"),
    # Anthropic (cloud)
    anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
    anthropic_base_url: System.get_env("ANTHROPIC_BASE_URL", "https://api.anthropic.com"),
    anthropic_model: System.get_env("ANTHROPIC_MODEL", "claude-3-haiku-20240307"),
    # Polymarket signal feed
    polymarket_gamma_url: System.get_env("POLYMARKET_GAMMA_URL", "https://gamma-api.polymarket.com"),
    polymarket_clob_url: System.get_env("POLYMARKET_CLOB_URL", "https://clob.polymarket.com"),
    polymarket_poll_interval_ms: String.to_integer(System.get_env("POLYMARKET_POLL_INTERVAL_S", "30")) * 1000,
    polymarket_shift_threshold: String.to_float(System.get_env("POLYMARKET_SHIFT_THRESHOLD", "0.10")),
    polymarket_min_volume: String.to_integer(System.get_env("POLYMARKET_MIN_VOLUME", "5000"))
end
