defmodule AlpacaTrader.LLM.OpinionGate do
  @moduledoc """
  LLM conviction gate with configurable provider failover chain.

  Enable providers via env vars (tried in order when multiple are enabled):
  - LLM_USE_MLX=true       — local MLX server, ~200ms
  - LLM_USE_OLLAMA=true    — remote Ollama, ~500ms
  - LLM_USE_CEREBRAS=true   — Cerebras free tier, ~80ms
  - LLM_USE_OPENROUTER=true — OpenRouter free models, ~1s
  - LLM_USE_ANTHROPIC=true  — Anthropic Claude, ~2s

  Falls back through enabled providers on failure.
  Returns 0.5 conviction fallback if no providers are enabled or all fail.
  """

  use GenServer

  require Logger

  @cache_table :llm_opinion_cache
  @cache_ttl_ms :timer.minutes(3)
  @min_conviction 0.3

  # ── Public API ─────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  # Runs entirely in the caller's process — no GenServer bottleneck.
  # ETS is :public so cache reads/writes are safe from any process.
  def evaluate(arb, ctx) do
    key = cache_key(arb)

    case check_cache(key) do
      {:ok, cached} ->
        GenServer.cast(__MODULE__, :hit)
        {:ok, cached}

      :miss ->
        opinion = call_with_failover(arb, ctx)
        cache(key, opinion)
        GenServer.cast(__MODULE__, :call)
        {:ok, opinion}
    end
  rescue
    _ -> {:ok, fallback()}
  end

  def call_count, do: GenServer.call(__MODULE__, :call_count)
  def enabled?, do: true
  def min_conviction, do: @min_conviction

  def fallback,
    do: %{decision: "confirm", conviction: 0.5, reasoning: "LLM unavailable", risk_flags: []}

  # ── GenServer ──────────────────────────────────────────────

  @impl true
  def init(_) do
    :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{calls: 0, hits: 0}}
  end

  @impl true
  def handle_cast(:call, state), do: {:noreply, %{state | calls: state.calls + 1}}

  @impl true
  def handle_cast(:hit, state), do: {:noreply, %{state | hits: state.hits + 1}}

  @impl true
  def handle_call(:call_count, _from, state), do: {:reply, state, state}

  # ── Provider Failover Chain ────────────────────────────────

  defp call_with_failover(arb, ctx) do
    providers =
      [
        {Application.get_env(:alpaca_trader, :llm_use_mlx, false),
         {:mlx, &call_openai_compatible/5,
          Application.get_env(:alpaca_trader, :llm_base_url, "http://localhost:8080"),
          Application.get_env(
            :alpaca_trader,
            :llm_model,
            "mlx-community/Phi-3.5-mini-instruct-4bit"
          ), nil, 8_000}},
        {Application.get_env(:alpaca_trader, :llm_use_ollama, false),
         {:ollama, &call_openai_compatible/5,
          Application.get_env(:alpaca_trader, :ollama_base_url, "https://ollama.lefv.info"),
          Application.get_env(:alpaca_trader, :ollama_model, "qwen3:8b"),
          Application.get_env(:alpaca_trader, :ollama_api_key),
          Application.get_env(:alpaca_trader, :ollama_timeout_ms, 30_000)}},
        {Application.get_env(:alpaca_trader, :llm_use_cerebras, false),
         {:cerebras, &call_openai_compatible/5,
          Application.get_env(:alpaca_trader, :cerebras_base_url, "https://api.cerebras.ai"),
          Application.get_env(:alpaca_trader, :cerebras_model, "llama3.1-8b"),
          Application.get_env(:alpaca_trader, :cerebras_api_key), 10_000}},
        {Application.get_env(:alpaca_trader, :llm_use_openrouter, false),
         {:openrouter, &call_openai_compatible/5,
          Application.get_env(:alpaca_trader, :openrouter_base_url, "https://openrouter.ai/api"),
          Application.get_env(
            :alpaca_trader,
            :openrouter_model,
            "meta-llama/llama-3.3-70b-instruct:free"
          ), Application.get_env(:alpaca_trader, :openrouter_api_key), 15_000}},
        {Application.get_env(:alpaca_trader, :llm_use_anthropic, false),
         {:anthropic, &call_anthropic/5,
          Application.get_env(:alpaca_trader, :anthropic_base_url, "https://api.anthropic.com"),
          Application.get_env(:alpaca_trader, :anthropic_model, "claude-haiku-4-5-20251001"),
          Application.get_env(:alpaca_trader, :anthropic_api_key), 10_000}}
      ]
      |> Enum.filter(fn {enabled, _} -> enabled end)
      |> Enum.map(fn {_, provider} -> provider end)

    if providers == [] do
      Logger.warning(
        "[LLM Gate] no providers enabled — set LLM_USE_MLX, LLM_USE_OLLAMA, or LLM_USE_ANTHROPIC"
      )
    end

    prompt = build_prompt(arb, ctx)

    Enum.reduce_while(providers, fallback(), fn {name, call_fn, url, model, key, timeout}, _acc ->
      try do
        case call_fn.(url, model, key, prompt, timeout) do
          %{decision: _} = opinion ->
            Logger.info(
              "[LLM Gate] #{name}: #{opinion.decision} conviction=#{opinion.conviction}"
            )

            {:halt, opinion}

          other ->
            Logger.warning(
              "[LLM Gate] #{name} returned: #{inspect(other) |> String.slice(0..80)}"
            )

            {:cont, fallback()}
        end
      rescue
        e ->
          Logger.warning("[LLM Gate] #{name} error: #{inspect(e) |> String.slice(0..80)}")
          {:cont, fallback()}
      catch
        _, _ ->
          Logger.warning("[LLM Gate] #{name} crashed, trying next")
          {:cont, fallback()}
      end
    end)
  end

  # ── OpenAI-Compatible (MLX, Ollama) ────────────────────────

  defp call_openai_compatible(base_url, model, api_key, prompt, timeout) do
    headers = [{"content-type", "application/json"}]
    headers = if api_key, do: [{"authorization", "Bearer #{api_key}"} | headers], else: headers

    body = %{
      model: model,
      max_tokens: 300,
      temperature: 0.1,
      messages: [
        %{role: "system", content: system_prompt()},
        %{role: "user", content: prompt}
      ]
    }

    case Req.post("#{base_url}/v1/chat/completions",
           json: body,
           headers: headers,
           receive_timeout: timeout,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
        result = parse_opinion(text)

        if result == nil do
          Logger.warning("[LLM Gate] PARSE FAIL: #{String.slice(text, 0..200)}")
        end

        result

      {:ok, %{status: status}} ->
        Logger.warning("[LLM Gate] HTTP #{status}")
        nil

      {:error, %{reason: :timeout}} ->
        Logger.warning("[LLM Gate] TIMEOUT (#{div(timeout, 1000)}s)")
        nil

      {:error, reason} ->
        Logger.warning("[LLM Gate] ERROR: #{inspect(reason) |> String.slice(0..80)}")
        nil

      other ->
        Logger.warning("[LLM Gate] UNEXPECTED: #{inspect(other) |> String.slice(0..120)}")
        nil
    end
  end

  # ── Anthropic Claude ───────────────────────────────────────

  defp call_anthropic(_base_url, _model, nil, _prompt, _timeout), do: nil

  defp call_anthropic(base_url, model, api_key, prompt, timeout) do
    body = %{
      model: model,
      max_tokens: 300,
      system: system_prompt(),
      messages: [%{role: "user", content: prompt}]
    }

    case Req.post("#{base_url}/v1/messages",
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"},
             {"content-type", "application/json"}
           ],
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        parse_opinion(text)

      {:ok, %{status: status, body: body}} ->
        Logger.warning(
          "[LLM Gate] Anthropic HTTP #{status}: #{inspect(body) |> String.slice(0..200)}"
        )

        nil

      {:error, reason} ->
        Logger.warning("[LLM Gate] Anthropic ERROR: #{inspect(reason) |> String.slice(0..80)}")
        nil
    end
  end

  # ── Prompt & Parse ─────────────────────────────────────────

  defp system_prompt do
    "You are a quantitative trading analyst scoring statistical arbitrage signals. " <>
      "Crypto trades 24/7 regardless of stock market hours. " <>
      "A z-score above 2.0 is a valid entry signal. Higher z-score = stronger signal. " <>
      "Respond ONLY with raw JSON: {\"decision\":\"confirm\",\"conviction\":0.7,\"reasoning\":\"...\",\"risk_flags\":[]}"
  end

  defp build_prompt(arb, _ctx) do
    is_crypto =
      String.contains?(arb.asset || "", "/") or String.contains?(arb.pair_asset || "", "/")

    n = length(AlpacaTrader.PairPositionStore.open_positions())

    "#{arb.asset} / #{arb.pair_asset || "-"} | #{arb.direction} | z=#{arb.z_score || "-"} | tier #{arb.tier} | #{arb.action} | #{if is_crypto, do: "CRYPTO (24/7)", else: "EQUITY"} | #{n} open positions\n#{arb.reason}\nScore this signal. JSON only."
  end

  defp parse_opinion(text) do
    cleaned =
      text
      |> String.replace(~r/```json\n?/, "")
      |> String.replace(~r/```\n?/, "")
      |> String.trim()

    # Try full JSON parse first
    result =
      case Jason.decode(cleaned) do
        {:ok, %{"decision" => d, "conviction" => c}} when is_number(c) ->
          %{decision: d, conviction: min(max(c * 1.0, 0.0), 1.0), reasoning: "", risk_flags: []}

        _ ->
          nil
      end

    # Fallback: extract with regex (handles truncated JSON from max_tokens)
    result || extract_with_regex(cleaned)
  end

  defp extract_with_regex(text) do
    # Try exact key names first, then fuzzy matches
    decision =
      case Regex.run(~r/"decision"\s*:\s*"(\w+)"/i, text) do
        [_, d] ->
          normalize_decision(d)

        _ ->
          cond do
            Regex.match?(~r/confirm/i, text) -> "confirm"
            Regex.match?(~r/suppress/i, text) -> "suppress"
            Regex.match?(~r/reduce/i, text) -> "reduce"
            true -> nil
          end
      end

    # Try conviction, confidence, score — any numeric score field
    conviction = extract_score(text)

    cond do
      decision && conviction ->
        %{decision: decision, conviction: conviction, reasoning: "", risk_flags: []}

      decision ->
        %{decision: decision, conviction: 0.7, reasoning: "inferred", risk_flags: []}

      conviction && conviction > 0.5 ->
        %{decision: "confirm", conviction: conviction, reasoning: "inferred", risk_flags: []}

      true ->
        nil
    end
  end

  defp normalize_decision(d) do
    d = String.downcase(d)

    cond do
      String.starts_with?(d, "confirm") -> "confirm"
      String.starts_with?(d, "suppress") -> "suppress"
      String.starts_with?(d, "reduce") -> "reduce"
      true -> d
    end
  end

  defp extract_score(text) do
    patterns = [
      ~r/"conviction"\s*:\s*([\d.]+)/i,
      ~r/"confidence"\s*:\s*([\d.]+)/i,
      ~r/"score"\s*:\s*([\d.]+)/i,
      ~r/conviction[:\s]+([\d.]+)/i,
      ~r/confidence[:\s]+([\d.]+)/i
    ]

    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, text) do
        [_, c] ->
          case Float.parse(c) do
            {f, _} when f >= 0.0 and f <= 1.0 -> f
            {f, _} when f > 1.0 and f <= 100.0 -> f / 100.0
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  # ── Cache ──────────────────────────────────────────────────

  defp cache_key(arb) do
    z = if is_number(arb.z_score), do: Float.round(arb.z_score * 2, 0) / 2, else: 0
    {arb.asset, arb.pair_asset, arb.direction, z}
  end

  defp check_cache(key) do
    case :ets.lookup(@cache_table, key) do
      [{^key, op, ts}] ->
        if System.monotonic_time(:millisecond) - ts < @cache_ttl_ms, do: {:ok, op}, else: :miss

      [] ->
        :miss
    end
  end

  defp cache(key, op),
    do: :ets.insert(@cache_table, {key, op, System.monotonic_time(:millisecond)})
end
