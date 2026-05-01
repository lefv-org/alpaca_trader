defmodule AlpacaTrader.StrategyRunner do
  @moduledoc """
  One GenServer per loaded Strategy. Holds the strategy's internal state
  and dispatches scan/exits/on_fill callbacks.
  """
  use GenServer

  def start_link({mod, config}) do
    GenServer.start_link(__MODULE__, {mod, config}, name: via(mod.id()))
  end

  def child_spec({mod, _config} = arg) do
    %{id: {__MODULE__, mod.id()}, start: {__MODULE__, :start_link, [arg]},
      restart: :permanent, type: :worker}
  end

  defp via(id), do: {:via, Registry, {AlpacaTrader.StrategyRunners, id}}

  # Default 25s matches the StrategyRegistry's per-task timeout. Strategies
  # whose scan/exits do live HTTP can exceed the GenServer.call default of
  # 5s on a slow venue. Without this override the registry's outer 30s
  # fan-out shield is bypassed by the inner 5s timeout, killing the runner.
  @strategy_call_timeout 25_000

  def scan(id, ctx), do: GenServer.call(via(id), {:scan, ctx}, @strategy_call_timeout)
  def exits(id, ctx), do: GenServer.call(via(id), {:exits, ctx}, @strategy_call_timeout)
  def on_fill(id, fill), do: GenServer.cast(via(id), {:fill, fill})

  @impl true
  def init({mod, config}) do
    {:ok, state} = mod.init(config)
    {:ok, %{mod: mod, state: state}}
  end

  @impl true
  def handle_call({:scan, ctx}, _from, %{mod: mod, state: s} = w) do
    safe_invoke(:scan, mod, s, ctx, w)
  end

  def handle_call({:exits, ctx}, _from, %{mod: mod, state: s} = w) do
    safe_invoke(:exits, mod, s, ctx, w)
  end

  # Wrap strategy callbacks so a single buggy module can't take down the
  # runner, drop the in-flight registry call, and force every subsequent
  # tick to wait the full 25 s GenServer.call timeout. Crashes are logged
  # and we reply with [] preserving the previous state.
  defp safe_invoke(kind, mod, s, ctx, w) do
    try do
      {:ok, sigs, s2} = apply(mod, kind, [s, ctx])
      {:reply, sigs, %{w | state: s2}}
    rescue
      e ->
        require Logger
        Logger.error(
          "[StrategyRunner #{inspect(mod)}] #{kind} crashed: #{Exception.message(e)} — preserving state"
        )

        {:reply, [], w}
    catch
      kind_caught, reason ->
        require Logger
        Logger.error(
          "[StrategyRunner #{inspect(mod)}] #{kind} #{kind_caught}: #{inspect(reason)} — preserving state"
        )

        {:reply, [], w}
    end
  end

  @impl true
  def handle_cast({:fill, fill}, %{mod: mod, state: s} = w) do
    {:ok, s2} = mod.on_fill(s, fill)
    {:noreply, %{w | state: s2}}
  end
end
