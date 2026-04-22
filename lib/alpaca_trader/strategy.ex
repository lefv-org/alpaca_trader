defmodule AlpacaTrader.Strategy do
  @moduledoc """
  Strategy abstraction. Each implementation runs as a supervised GenServer.
  Strategies emit %Signal{} lists; they never call brokers or HTTP directly.
  """

  alias AlpacaTrader.Types.{Signal, Fill, FeedSpec}

  @callback id() :: atom
  @callback required_feeds() :: [FeedSpec.t()]
  @callback init(config :: map) :: {:ok, state :: term} | {:error, term}
  @callback scan(state :: term, ctx :: map) ::
              {:ok, [Signal.t()], new_state :: term}
  @callback exits(state :: term, ctx :: map) ::
              {:ok, [Signal.t()], new_state :: term}
  @callback on_fill(state :: term, Fill.t()) :: {:ok, new_state :: term}
end
