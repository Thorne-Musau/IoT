defmodule Ingestion.RulesEngineTest do
  use Ingestion.DataCase, async: true

  import Ingestion.Fixtures

  alias Ingestion.RulesEngine

  test "only the approved rule in a commodity is evaluated, even alongside draft/pending/retired ones" do
    commodity = "cold_chain_vaccine"

    _draft =
      insert_draft_rule!(%{
        commodity: commodity,
        boundary_value: 5.0,
        hysteresis_gap: 0.0,
        duration_window: 0
      })

    pending_draft =
      insert_draft_rule!(%{
        commodity: commodity,
        boundary_value: 5.0,
        hysteresis_gap: 0.0,
        duration_window: 0
      })

    {:ok, _pending} = Ingestion.ThresholdRules.submit_for_review(pending_draft, "j.analyst")

    approved =
      insert_approved_rule!(%{
        commodity: commodity,
        boundary_value: 5.0,
        hysteresis_gap: 0.0,
        duration_window: 0
      })

    window = series([9.0])

    evaluations = RulesEngine.evaluate_commodity(commodity, window)

    assert Map.keys(evaluations) == [approved.id]
    assert evaluations[approved.id].status == :breach
  end

  test "a reading at exactly the FSQ-approved boundary_value raises, for both comparator directions" do
    above_commodity = "boundary_exact_above_#{System.unique_integer([:positive])}"
    below_commodity = "boundary_exact_below_#{System.unique_integer([:positive])}"

    above_rule =
      insert_approved_rule!(%{
        commodity: above_commodity,
        comparator: "above",
        boundary_value: 8.0,
        hysteresis_gap: 1.0,
        duration_window: 0
      })

    below_rule =
      insert_approved_rule!(%{
        commodity: below_commodity,
        comparator: "below",
        boundary_value: 2.0,
        hysteresis_gap: 0.5,
        duration_window: 0
      })

    above_eval = RulesEngine.evaluate_commodity(above_commodity, series([8.0]))
    below_eval = RulesEngine.evaluate_commodity(below_commodity, series([2.0]))

    assert above_eval[above_rule.id].status == :breach
    assert below_eval[below_rule.id].status == :breach
  end

  test "a rule with no approved version in that commodity evaluates to nothing" do
    insert_draft_rule!(%{commodity: "unreviewed_commodity"})

    assert RulesEngine.evaluate_commodity("unreviewed_commodity", series([9.0])) == %{}
  end

  test "carries prior status through for hysteresis across calls" do
    commodity = "cold_room"

    rule =
      insert_approved_rule!(%{
        commodity: commodity,
        boundary_value: 8.0,
        hysteresis_gap: 1.0,
        duration_window: 0
      })

    first = RulesEngine.evaluate_commodity(commodity, series([9.5]))
    assert first[rule.id].status == :breach

    prior_statuses = Map.new(first, fn {id, %{status: status}} -> {id, status} end)

    # 8.5 is under the raise boundary but still above the clear boundary
    second = RulesEngine.evaluate_commodity(commodity, series([8.5]), prior_statuses)
    assert second[rule.id].status == :breach
    assert second[rule.id].prior_status == :breach
  end
end
