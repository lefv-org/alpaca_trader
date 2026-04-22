defmodule AlpacaTrader.MarketDataBus do
  @moduledoc """
  Fan-out broadcaster for ticks, fills, and account updates from all brokers.
  Subscribers are pids that receive `{:market_data, event}` messages.

  Simple GenServer + MapSet — no GenStage back-pressure yet. Upgrade path
  if subscriber count or event rate demands it.
  """
  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, name: name)
  end

  def subscribe(bus \\ __MODULE__, pid), do: GenServer.call(bus, {:sub, pid})
  def publish(bus \\ __MODULE__, event), do: GenServer.cast(bus, {:pub, event})

  @impl true
  def init(_), do: {:ok, %{subs: MapSet.new(), refs: %{}}}

  @impl true
  def handle_call({:sub, pid}, _, %{subs: subs, refs: refs} = state) do
    if MapSet.member?(subs, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)
      {:reply, :ok, %{state | subs: MapSet.put(subs, pid), refs: Map.put(refs, ref, pid)}}
    end
  end

  @impl true
  def handle_cast({:pub, event}, %{subs: subs} = state) do
    for pid <- subs, do: send(pid, {:market_data, event})
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{subs: subs, refs: refs} = state) do
    case Map.pop(refs, ref) do
      {nil, _} -> {:noreply, state}
      {pid, refs2} -> {:noreply, %{state | subs: MapSet.delete(subs, pid), refs: refs2}}
    end
  end
end
