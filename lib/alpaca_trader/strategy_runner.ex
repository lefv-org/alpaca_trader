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

  def scan(id, ctx), do: GenServer.call(via(id), {:scan, ctx})
  def exits(id, ctx), do: GenServer.call(via(id), {:exits, ctx})
  def on_fill(id, fill), do: GenServer.cast(via(id), {:fill, fill})

  @impl true
  def init({mod, config}) do
    {:ok, state} = mod.init(config)
    {:ok, %{mod: mod, state: state}}
  end

  @impl true
  def handle_call({:scan, ctx}, _from, %{mod: mod, state: s} = w) do
    {:ok, sigs, s2} = mod.scan(s, ctx)
    {:reply, sigs, %{w | state: s2}}
  end

  def handle_call({:exits, ctx}, _from, %{mod: mod, state: s} = w) do
    {:ok, sigs, s2} = mod.exits(s, ctx)
    {:reply, sigs, %{w | state: s2}}
  end

  @impl true
  def handle_cast({:fill, fill}, %{mod: mod, state: s} = w) do
    {:ok, s2} = mod.on_fill(s, fill)
    {:noreply, %{w | state: s2}}
  end
end
