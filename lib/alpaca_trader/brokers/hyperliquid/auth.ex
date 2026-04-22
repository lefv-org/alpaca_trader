defmodule AlpacaTrader.Brokers.Hyperliquid.Auth do
  @moduledoc """
  EIP-712 signing stub for Hyperliquid API.

  Real implementation requires secp256k1 signing over the action's EIP-712
  domain separator + struct hash. That is intentionally deferred — live
  submit will not work until this is replaced. Read + public info endpoints
  work without signatures.

  When HL_API_WALLET_KEY is absent, `sign/2` returns `{:error, :no_key}`.
  When present, it returns a deterministic stub signature so higher-level
  code paths can be exercised in tests. Replacing this module with real
  signing is the gate for live Hyperliquid trading.
  """

  @spec sign(map, keyword) :: {:ok, String.t()} | {:error, term}
  def sign(action, _opts \\ []) do
    case Application.get_env(:alpaca_trader, :hyperliquid_api_key) do
      nil -> {:error, :no_key}
      _key -> {:ok, "stub-sig-#{:erlang.phash2(action)}"}
    end
  end
end
