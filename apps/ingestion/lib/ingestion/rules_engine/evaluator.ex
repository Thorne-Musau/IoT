defmodule Ingestion.RulesEngine.Evaluator do
  @moduledoc """
  Pure evaluation of one rule against one sensor's reading window.

  Implements the three pieces of intelligence Phase 2 requires:

    * **Duration gating** — a breach only fires once readings have been on
      the breach side of the rule's *raise* boundary continuously for at
      least `duration_window` seconds. A single spiky reading does not
      raise an alert.
    * **Rate-of-change trending** — before the boundary is actually
      crossed, a reading moving toward it fast enough (per
      `rate_of_change_threshold`, unit/second) is flagged `:trending`: a
      distinct, lower-severity precursor state.
    * **Hysteresis** — a breach always raises exactly at the FSQ-approved
      `boundary_value` (`Rule.raise_boundary/1`) — `hysteresis_gap` never
      loosens that. But once `:breach`, the rule does not drop back to
      `:normal` just because one reading recrosses `boundary_value`; it
      must improve `hysteresis_gap` further, past the stricter
      `clear_boundary/1`, first. This keeps a reading oscillating right at
      the boundary from flapping the alert, without ever alerting later
      than what FSQ approved.

  The window is assumed most-recent-first (`Ingestion.SensorState.Server`'s
  existing convention: `[newest | ...]`).
  """

  alias Ingestion.RulesEngine.Rule

  @type reading :: %{value: number(), recorded_at: DateTime.t()}
  @type status :: :normal | :trending | :breach

  @doc """
  Evaluates `rule` against `window`, given the rule's previous status for
  this sensor (`:normal` if never evaluated before). Returns the new
  status.
  """
  @spec evaluate(Rule.t(), [reading()], status()) :: status()
  def evaluate(%Rule{} = _rule, [], _prior_status), do: :normal

  def evaluate(%Rule{} = rule, [newest | _] = window, prior_status) do
    cond do
      prior_status == :breach ->
        if cleared?(rule, newest) do
          :normal
        else
          :breach
        end

      sustained_breach?(rule, window) ->
        :breach

      trending?(rule, window) ->
        :trending

      true ->
        :normal
    end
  end

  defp cleared?(rule, %{value: value}) do
    Rule.cleared_at?(rule, value, Rule.clear_boundary(rule))
  end

  defp sustained_breach?(rule, window) do
    raise_boundary = Rule.raise_boundary(rule)

    case Enum.take_while(window, fn r -> Rule.breached_at?(rule, r.value, raise_boundary) end) do
      [] ->
        false

      run ->
        newest = List.first(run)
        oldest = List.last(run)
        DateTime.diff(newest.recorded_at, oldest.recorded_at) >= rule.duration_window
    end
  end

  defp trending?(%Rule{rate_of_change_threshold: nil}, _window), do: false

  defp trending?(rule, [newest, previous | _]) do
    raise_boundary = Rule.raise_boundary(rule)

    already_breached? = Rule.breached_at?(rule, newest.value, raise_boundary)
    seconds = DateTime.diff(newest.recorded_at, previous.recorded_at)

    cond do
      already_breached? or seconds <= 0 ->
        false

      true ->
        rate = (newest.value - previous.value) / seconds
        moving_toward_boundary?(rule, rate) and abs(rate) >= rule.rate_of_change_threshold
    end
  end

  defp trending?(_rule, _window), do: false

  defp moving_toward_boundary?(%Rule{comparator: :above}, rate), do: rate > 0
  defp moving_toward_boundary?(%Rule{comparator: :below}, rate), do: rate < 0
end
