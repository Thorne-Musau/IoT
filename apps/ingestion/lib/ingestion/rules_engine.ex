defmodule Ingestion.RulesEngine do
  @moduledoc """
  The rules-engine boundary: fetches a commodity's `approved` rules and
  evaluates each against a sensor's reading window.

  This is the only place that bridges the impure world (loading rules from
  `Ingestion.ThresholdRules`) with the pure `Ingestion.RulesEngine.Evaluator`.
  Because rules only ever reach the evaluator via `Rule.from_schema!/1`
  (which raises on anything not `approved`), a `draft` or
  `pending_fsq_review` rule cannot be evaluated even if it somehow ended up
  in the list this module fetches.
  """

  alias Ingestion.RulesEngine.{Evaluator, Rule}
  alias Ingestion.ThresholdRules

  @type status :: Evaluator.status()
  @type evaluation :: %{rule: Rule.t(), prior_status: status(), status: status()}

  @doc """
  Evaluates every `approved` rule for `commodity` against `window`.

  `prior_statuses` is a `%{rule_id => status}` map (typically the caller's
  running state, e.g. `Ingestion.SensorState.Server`'s), used to carry
  hysteresis across calls. Returns a map of the same shape keyed by rule
  id, so the caller can diff `prior_status` vs `status` to detect
  transitions worth acting on.
  """
  @spec evaluate_commodity(String.t(), [Evaluator.reading()], %{integer() => status()}) ::
          %{integer() => evaluation()}
  def evaluate_commodity(commodity, window, prior_statuses \\ %{}) do
    commodity
    |> ThresholdRules.list_approved_rules_for_commodity()
    |> Map.new(fn schema ->
      rule = Rule.from_schema!(schema)
      prior_status = Map.get(prior_statuses, rule.id, :normal)
      status = Evaluator.evaluate(rule, window, prior_status)

      {rule.id, %{rule: rule, prior_status: prior_status, status: status}}
    end)
  end
end
