defmodule AlpacaTrader.LLM.OpinionGate do
  @moduledoc """
  LLM conviction gate for trade decisions.
  Uses local MLX server (Ministral) for fast inference.
  Falls back gracefully if LLM is unavailable.
  """

  use GenServer

  require Logger

  @cache_table :llm_opinion_cache
  @cache_ttl_ms :timer.minutes(3)
  @min_conviction 0.3

  # ── Public API ─────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def evaluate(arb, ctx) do
    try do
      GenServer.call(__MODULE__, {:evaluate, arb, ctx}, 10_000)
    catch
      :exit, _ ->
        Logger.warning("[LLM Gate] timeout, using fallback")
        {:ok, fallback()}
    end
  end

  def call_count, do: GenServer.call(__MODULE__, :call_count)
  def enabled?, do: true
  def min_conviction, do: @min_conviction
  def fallback do
    %{decision: "confirm", conviction: 0.5, reasoning: "LLM unavailable, default", risk_flags: []}
  end

  # ── GenServer ──────────────────────────────────────────────

  @impl true
  def init(_) do
    :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{calls: 0, hits: 0}}
  end

  @impl true
  def handle_call({:evaluate, arb, ctx}, _from, state) do
    cache_key = build_cache_key(arb)

    case check_cache(cache_key) do
      {:ok, cached} ->
        {:reply, {:ok, cached}, %{state | hits: state.hits + 1}}

      :miss ->
        opinion = call_llm(arb, ctx)
        cache_opinion(cache_key, opinion)
        {:reply, {:ok, opinion}, %{state | calls: state.calls + 1}}
    end
  end

  @impl true
  def handle_call(:call_count, _from, state), do: {:reply, state, state}

  # ── LLM Call (OpenAI-compatible, local MLX) ────────────────

  defp call_llm(arb, ctx) do
    prompt = build_prompt(arb, ctx)
    base_url = Application.get_env(:alpaca_trader, :llm_base_url, "http://localhost:8080")
    model = Application.get_env(:alpaca_trader, :llm_model, "mlx-community/Ministral-3-8B-Instruct-2512-4bit")

    body = %{
      model: model,
      max_tokens: 200,
      temperature: 0.1,
      messages: [
        %{role: "system", content: system_prompt()},
        %{role: "user", content: prompt}
      ]
    }

    case Req.post("#{base_url}/v1/chat/completions",
      json: body,
      headers: [{"content-type", "application/json"}],
      receive_timeout: 8_000
    ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
        parse_opinion(text)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[LLM Gate] #{status}: #{inspect(body) |> String.slice(0..100)}")
        fallback()

      {:error, reason} ->
        Logger.warning("[LLM Gate] failed: #{inspect(reason)}")
        fallback()
    end
  end

  # ── Prompt ─────────────────────────────────────────────────

  defp system_prompt do
    """
    You are a trading risk analyst. You evaluate statistical arbitrage signals.
    You NEVER generate trade ideas — only score proposals.
    Respond in JSON only: {"decision":"confirm"|"suppress"|"reduce","conviction":0.0-1.0,"reasoning":"...","risk_flags":[]}
    Be concise. One sentence reasoning max.
    """
  end

  defp build_prompt(arb, ctx) do
    market_open = get_in(ctx.clock, ["is_open"]) || false
    open_count = length(AlpacaTrader.PairPositionStore.open_positions())

    """
    Pair: #{arb.asset}/#{arb.pair_asset || "N/A"} | Direction: #{arb.direction || "single"} | Z: #{arb.z_score || "N/A"} | Tier: #{arb.tier} | Action: #{arb.action}
    Market: #{if market_open, do: "OPEN", else: "CLOSED"} | Open positions: #{open_count}
    Signal: #{arb.reason}
    Evaluate. JSON only.
    """
  end

  # ── Parse ──────────────────────────────────────────────────

  defp parse_opinion(text) do
    # Extract JSON from possible markdown code blocks or raw text
    cleaned = text
      |> String.replace(~r/```json\n?/, "")
      |> String.replace(~r/```\n?/, "")
      |> String.trim()

    # Find the first complete JSON object
    json_str = case Regex.run(~r/\{[^{}]*("decision"|"conviction")[^{}]*\}/s, cleaned) do
      [json] -> json
      _ -> cleaned
    end

    case Jason.decode(json_str) do
      {:ok, %{"decision" => d, "conviction" => c} = map} when is_number(c) ->
        %{
          decision: d,
          conviction: c,
          reasoning: Map.get(map, "reasoning", "") |> to_string() |> String.slice(0..100),
          risk_flags: Map.get(map, "risk_flags", [])
        }

      _ ->
        Logger.warning("[LLM Gate] unparseable: #{String.slice(text, 0..80)}")
        fallback()
    end
  end

  # ── Cache ──────────────────────────────────────────────────

  defp build_cache_key(arb) do
    z = if is_number(arb.z_score), do: Float.round(arb.z_score * 2, 0) / 2, else: 0
    {arb.asset, arb.pair_asset, arb.direction, z}
  end

  defp check_cache(key) do
    case :ets.lookup(@cache_table, key) do
      [{^key, opinion, ts}] ->
        if System.monotonic_time(:millisecond) - ts < @cache_ttl_ms,
          do: {:ok, opinion}, else: :miss
      [] -> :miss
    end
  end

  defp cache_opinion(key, opinion) do
    :ets.insert(@cache_table, {key, opinion, System.monotonic_time(:millisecond)})
  end
end
