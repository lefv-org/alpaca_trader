defmodule AlpacaTrader.Microstructure.OrderFlowImbalance do
  @moduledoc """
  Order Flow Imbalance (OFI) — Cont, Kukanov & Stoikov,
  The Price Impact of Order Book Events, J. Financial Econometrics 12(1), 2014.

  ## Definition

  Given two consecutive top-of-book quotes (bid b, ask a, sizes Sb, Sa):

      ΔSb = Sb_t  - (Sb_{t-1} if b_t == b_{t-1} else 0)
      ΔSa = Sa_t  - (Sa_{t-1} if a_t == a_{t-1} else 0)

      e_n =  ΔSb · 1[b_t > b_{t-1}]   +    -- bid up
            -ΔSb · 1[b_t < b_{t-1}]   +    -- bid down (negative contrib)
            -ΔSa · 1[a_t > a_{t-1}]   +    -- ask up   (negative contrib)
             ΔSa · 1[a_t < a_{t-1}]         -- ask down

      OFI_n = sum of e_n over a window

  Cont/Kukanov/Stoikov show:
    ΔP / OFI ≈ k / depth  (linear, slope inversely proportional to market depth)

  This is a *feature engineering* module, not a strategy: it produces
  a real-valued alpha signal that strategies (the AvellanedaStoikov GLFT
  extension, an OBI replacement, or any future ML head) can consume.

  ## Usage

      {:ok, ofi, new_state} =
        OrderFlowImbalance.update(state, %{bid: 100.0, ask: 100.05, bid_size: 1000, ask_size: 800})

  state shape:
      %{prev_quote: %{...} | nil, history: [e_n, ...]}

  Returns:
    * ofi — sum over the configured window (default 20 ticks)
    * new_state — accumulator for the next call
  """

  defstruct prev_quote: nil, history: [], window: 20

  @type t :: %__MODULE__{
          prev_quote: map | nil,
          history: [number],
          window: pos_integer
        }

  @type quote_t :: %{
          required(:bid) => number,
          required(:ask) => number,
          required(:bid_size) => number,
          required(:ask_size) => number
        }

  @spec new(window :: pos_integer) :: t
  def new(window \\ 20), do: %__MODULE__{window: window}

  @spec update(t, quote_t) :: {:ok, float, t}
  def update(%__MODULE__{prev_quote: nil} = state, quote) do
    {:ok, 0.0, %{state | prev_quote: quote}}
  end

  def update(%__MODULE__{prev_quote: prev, history: hist, window: w} = state, quote) do
    e_n = compute_event_contribution(prev, quote)
    new_hist = Enum.take([e_n | hist], w)
    ofi = Enum.sum(new_hist)
    {:ok, ofi, %{state | prev_quote: quote, history: new_hist}}
  end

  # ── Core formula ────────────────────────────────────────────────────────────

  defp compute_event_contribution(
         %{bid: pb, ask: pa, bid_size: sb, ask_size: sa},
         %{bid: nb, ask: na, bid_size: nsb, ask_size: nsa}
       ) do
    bid_contrib =
      cond do
        nb > pb -> nsb * 1.0
        nb < pb -> -nsb * 1.0
        # equal: only the size delta counts
        true -> (nsb - sb) * 1.0
      end

    ask_contrib =
      cond do
        na > pa -> -nsa * 1.0
        na < pa -> nsa * 1.0
        true -> -(nsa - sa) * 1.0
      end

    bid_contrib + ask_contrib
  end

  defp compute_event_contribution(_prev, _quote), do: 0.0

  @doc """
  Normalised OFI: scaled by recent average depth so the value is
  approximately mean-zero, unit-variance. Useful as a feature for
  consumers that expect z-score-like inputs.
  """
  @spec normalised(t) :: float
  def normalised(%__MODULE__{history: []}), do: 0.0

  def normalised(%__MODULE__{history: hist}) do
    sum = Enum.sum(hist)
    n = length(hist)
    mean = sum / n

    var =
      Enum.reduce(hist, 0.0, fn x, acc -> acc + (x - mean) * (x - mean) end) / max(n - 1, 1)

    sd = :math.sqrt(var)

    if sd == 0.0, do: 0.0, else: sum / sd
  end
end
