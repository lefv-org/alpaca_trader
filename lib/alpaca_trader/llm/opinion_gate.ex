defmodule AlpacaTrader.LLM.OpinionGate do
  @moduledoc """
  LLM conviction gate for trade decisions.
  Calls Claude to score arbitrage signals before execution.
  Never generates signals — only evaluates proposals from the quant system.

  Uses the praxis pattern: proxy through local Claude Pro Max subscription
  via ANTHROPIC_API_KEY. Falls back gracefully if LLM is unavailable.
  """

  use GenServer

  require Logger

  @cache_table :llm_opinion_cache
  @cache_ttl_ms :timer.minutes(3)
  @min_conviction 0.3
  @default_model "claude-haiku-4-5-20250501"

  # ── Public API ─────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Evaluate a trade signal. Returns {:ok, opinion} where opinion has:
    decision: "confirm" | "suppress" | "reduce"
    conviction: 0.0 - 1.0
    reasoning: string
    risk_flags: [string]
  """
  def evaluate(arb, ctx) do
    try do
      GenServer.call(__MODULE__, {:evaluate, arb, ctx}, 15_000)
    catch
      :exit, _ ->
        Logger.warning("[LLM Gate] timeout, using fallback")
        {:ok, fallback()}
    end
  end

  @doc "How many LLM calls have been made this session."
  def call_count do
    GenServer.call(__MODULE__, :call_count)
  end

  @doc "Check if the LLM gate is enabled (API key configured)."
  def enabled? do
    api_key() != nil
  end

  # ── GenServer ──────────────────────────────────────────────

  @impl true
  def init(_) do
    :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{calls: 0, hits: 0, misses: 0}}
  end

  @impl true
  def handle_call({:evaluate, arb, ctx}, _from, state) do
    if not enabled?() do
      {:reply, {:ok, fallback()}, state}
    else
      cache_key = build_cache_key(arb)

      case check_cache(cache_key) do
        {:ok, cached} ->
          {:reply, {:ok, cached}, %{state | hits: state.hits + 1}}

        :miss ->
          opinion = call_claude(arb, ctx)
          cache_opinion(cache_key, opinion)
          {:reply, {:ok, opinion}, %{state | calls: state.calls + 1, misses: state.misses + 1}}
      end
    end
  end

  @impl true
  def handle_call(:call_count, _from, state) do
    {:reply, state, state}
  end

  # ── Claude API ─────────────────────────────────────────────

  defp call_claude(arb, ctx) do
    prompt = build_prompt(arb, ctx)

    body = %{
      model: select_model(arb),
      max_tokens: 200,
      system: system_prompt(),
      messages: [%{role: "user", content: prompt}]
    }

    base_url = Application.get_env(:alpaca_trader, :anthropic_base_url, "https://api.anthropic.com")

    case Req.post("#{base_url}/v1/messages",
      json: body,
      headers: [
        {"x-api-key", api_key()},
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"}
      ],
      receive_timeout: 12_000
    ) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        parse_opinion(text)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[LLM Gate] API #{status}: #{inspect(body) |> String.slice(0..100)}")
        fallback()

      {:error, reason} ->
        Logger.warning("[LLM Gate] request failed: #{inspect(reason)}")
        fallback()
    end
  end

  defp select_model(%{z_score: z}) when is_number(z) and abs(z) > 3.5 do
    # High z-score = unusual signal, use smarter model
    Application.get_env(:alpaca_trader, :llm_strong_model, "claude-sonnet-4-5-20250514")
  end

  defp select_model(_), do: Application.get_env(:alpaca_trader, :llm_model, @default_model)

  defp api_key do
    Application.get_env(:alpaca_trader, :anthropic_api_key) ||
      System.get_env("ANTHROPIC_API_KEY")
  end

  # ── Prompt Construction ────────────────────────────────────

  defp system_prompt do
    """
    You are a quantitative trading risk analyst. You receive statistical arbitrage
    signals and provide a conviction score. You NEVER generate trade ideas — you
    only evaluate proposals from the quant system. Be skeptical of weak signals.

    Respond in JSON only with exactly these keys:
    - decision: "confirm" or "suppress" or "reduce"
    - conviction: number 0.0 to 1.0
    - reasoning: string, 1-2 sentences
    - risk_flags: array of strings (empty if none)
    """
  end

  defp build_prompt(arb, ctx) do
    market_open = get_in(ctx.clock, ["is_open"]) || false
    open_count = length(AlpacaTrader.PairPositionStore.open_positions())
    equity = get_in(ctx.account, ["equity"]) || "?"

    """
    ## Proposed Trade
    - Pair: #{arb.asset} / #{arb.pair_asset || "N/A"}
    - Direction: #{arb.direction || "single-leg"}
    - Z-Score: #{arb.z_score || "N/A"}
    - Hedge Ratio: #{arb.hedge_ratio || "N/A"}
    - Tier: #{arb.tier}
    - Action: #{arb.action}

    ## Market State
    - Market open: #{market_open}
    - Account equity: $#{equity}
    - Open pair positions: #{open_count}

    ## Signal
    #{arb.reason}

    Evaluate this trade. JSON only.
    """
  end

  # ── Response Parsing ───────────────────────────────────────

  defp parse_opinion(text) do
    # Try to extract JSON from the response
    json_str = extract_json(text)

    case Jason.decode(json_str) do
      {:ok, %{"decision" => d, "conviction" => c} = map} when is_number(c) ->
        %{
          decision: d,
          conviction: c,
          reasoning: Map.get(map, "reasoning", ""),
          risk_flags: Map.get(map, "risk_flags", [])
        }

      _ ->
        Logger.warning("[LLM Gate] unparseable: #{String.slice(text, 0..100)}")
        fallback()
    end
  end

  defp extract_json(text) do
    # Handle cases where LLM wraps JSON in markdown code blocks
    case Regex.run(~r/\{[^}]+\}/s, text) do
      [json] -> json
      _ -> text
    end
  end

  # ── Caching ────────────────────────────────────────────────

  defp build_cache_key(arb) do
    z_bucket = if is_number(arb.z_score), do: Float.round(arb.z_score * 2, 0) / 2, else: 0
    {arb.asset, arb.pair_asset, arb.direction, z_bucket}
  end

  defp check_cache(key) do
    case :ets.lookup(@cache_table, key) do
      [{^key, opinion, ts}] ->
        if System.monotonic_time(:millisecond) - ts < @cache_ttl_ms,
          do: {:ok, opinion},
          else: :miss

      [] ->
        :miss
    end
  end

  defp cache_opinion(key, opinion) do
    :ets.insert(@cache_table, {key, opinion, System.monotonic_time(:millisecond)})
  end

  # ── Fallback ───────────────────────────────────────────────

  @doc "Default opinion when LLM is unavailable. Allows trade at reduced conviction."
  def fallback do
    %{
      decision: "confirm",
      conviction: 0.5,
      reasoning: "LLM unavailable, default conviction",
      risk_flags: []
    }
  end

  @doc "Minimum conviction threshold to execute a trade."
  def min_conviction, do: @min_conviction
end
