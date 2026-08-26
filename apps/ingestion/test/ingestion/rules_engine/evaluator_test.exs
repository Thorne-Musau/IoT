defmodule Ingestion.RulesEngine.EvaluatorTest do
  use ExUnit.Case, async: true

  import Ingestion.Fixtures

  alias Ingestion.RulesEngine.Evaluator

  describe "duration gating" do
    test "a single reading past the boundary does not raise a breach" do
      rule =
        rule(comparator: :above, boundary_value: 8.0, hysteresis_gap: 0.0, duration_window: 300)

      window = series([7.0, 9.0], step_seconds: 60)

      assert Evaluator.evaluate(rule, window, :normal) == :normal
    end

    test "a breach sustained for less than duration_window stays normal" do
      rule =
        rule(comparator: :above, boundary_value: 8.0, hysteresis_gap: 0.0, duration_window: 300)

      # 3 points, 60s apart => 120s of sustained breach, short of the 300s window
      window = series([9.0, 9.1, 9.2], step_seconds: 60)

      assert Evaluator.evaluate(rule, window, :normal) == :normal
    end

    test "a breach sustained for at least duration_window raises" do
      rule =
        rule(comparator: :above, boundary_value: 8.0, hysteresis_gap: 0.0, duration_window: 300)

      # 6 points, 60s apart => 300s of sustained breach
      window = series([9.0, 9.0, 9.0, 9.0, 9.0, 9.0], step_seconds: 60)

      assert Evaluator.evaluate(rule, window, :normal) == :breach
    end

    test "a dip below the boundary partway through resets the sustained run" do
      rule =
        rule(comparator: :above, boundary_value: 8.0, hysteresis_gap: 0.0, duration_window: 300)

      # breach only resumed 120s ago (2 points at 60s spacing), even though an
      # older breach happened further back
      window = series([9.0, 7.0, 9.0, 9.0, 9.0], step_seconds: 60)

      assert Evaluator.evaluate(rule, window, :normal) == :normal
    end

    test "duration_window of 0 raises immediately on the first breaching reading" do
      rule =
        rule(comparator: :above, boundary_value: 8.0, hysteresis_gap: 0.0, duration_window: 0)

      window = series([9.0])

      assert Evaluator.evaluate(rule, window, :normal) == :breach
    end

    test "a below-boundary rule gates the same way in the opposite direction" do
      rule =
        rule(comparator: :below, boundary_value: 2.0, hysteresis_gap: 0.0, duration_window: 300)

      window = series([1.0, 1.0, 1.0, 1.0, 1.0, 1.0], step_seconds: 60)

      assert Evaluator.evaluate(rule, window, :normal) == :breach
    end
  end

  describe "hysteresis" do
    test "raises exactly at boundary_value — hysteresis_gap adds no unapproved margin to the raise side" do
      rule =
        rule(comparator: :above, boundary_value: 8.0, hysteresis_gap: 1.0, duration_window: 0)

      assert Evaluator.evaluate(rule, series([8.0]), :normal) == :breach
    end

    test "a reading just under boundary_value does not raise" do
      rule =
        rule(comparator: :above, boundary_value: 8.0, hysteresis_gap: 1.0, duration_window: 0)

      assert Evaluator.evaluate(rule, series([7.9]), :normal) == :normal
    end

    test "once breached, a reading back under boundary_value does not clear the alert" do
      rule =
        rule(comparator: :above, boundary_value: 8.0, hysteresis_gap: 1.0, duration_window: 0)

      # 7.5 is back under the 8.0 raise boundary but short of the stricter
      # 7.0 clear boundary (8.0 - hysteresis_gap)
      assert Evaluator.evaluate(rule, series([7.5]), :breach) == :breach
    end

    test "clearing requires improving hysteresis_gap past boundary_value" do
      rule =
        rule(comparator: :above, boundary_value: 8.0, hysteresis_gap: 1.0, duration_window: 0)

      assert Evaluator.evaluate(rule, series([7.0]), :breach) == :normal
    end

    test "does not flap while oscillating inside the hysteresis band" do
      rule =
        rule(comparator: :above, boundary_value: 8.0, hysteresis_gap: 1.0, duration_window: 0)

      status =
        [9.5, 8.3, 8.7, 8.1, 8.9]
        |> Enum.reduce(:normal, fn value, status ->
          Evaluator.evaluate(rule, series([value]), status)
        end)

      assert status == :breach
    end

    test "hysteresis works symmetrically for a below-boundary rule" do
      rule =
        rule(comparator: :below, boundary_value: 2.0, hysteresis_gap: 0.5, duration_window: 0)

      # raise boundary is the plain 2.0, clear boundary is 2.5 (2.0 + hysteresis_gap)
      assert Evaluator.evaluate(rule, series([2.0]), :normal) == :breach
      assert Evaluator.evaluate(rule, series([2.3]), :breach) == :breach
      assert Evaluator.evaluate(rule, series([2.5]), :breach) == :normal
    end
  end

  describe "rate-of-change trending" do
    test "a fast approach toward the boundary trends before it is crossed" do
      rule =
        rule(
          comparator: :above,
          boundary_value: 8.0,
          hysteresis_gap: 1.0,
          duration_window: 300,
          rate_of_change_threshold: 0.5
        )

      window = series([6.0, 7.5], step_seconds: 2)

      assert Evaluator.evaluate(rule, window, :normal) == :trending
    end

    test "a slow approach does not trend" do
      rule =
        rule(
          comparator: :above,
          boundary_value: 8.0,
          hysteresis_gap: 1.0,
          duration_window: 300,
          rate_of_change_threshold: 0.5
        )

      window = series([6.0, 6.2], step_seconds: 2)

      assert Evaluator.evaluate(rule, window, :normal) == :normal
    end

    test "fast movement away from the boundary does not trend" do
      rule =
        rule(
          comparator: :above,
          boundary_value: 8.0,
          hysteresis_gap: 1.0,
          duration_window: 300,
          rate_of_change_threshold: 0.5
        )

      window = series([5.0, 3.0], step_seconds: 2)

      assert Evaluator.evaluate(rule, window, :normal) == :normal
    end

    test "trending is skipped once the rule has already breached" do
      rule =
        rule(
          comparator: :above,
          boundary_value: 8.0,
          hysteresis_gap: 0.0,
          duration_window: 0,
          rate_of_change_threshold: 0.1
        )

      window = series([8.5, 9.5], step_seconds: 2)

      assert Evaluator.evaluate(rule, window, :normal) == :breach
    end

    test "trending is a distinct, lower-severity precursor to a full breach across successive readings" do
      rule =
        rule(
          comparator: :above,
          boundary_value: 8.0,
          hysteresis_gap: 1.0,
          duration_window: 120,
          rate_of_change_threshold: 0.5
        )

      normal_status = Evaluator.evaluate(rule, series([6.0, 6.0]), :normal)
      trending_status = Evaluator.evaluate(rule, series([6.0, 7.5], step_seconds: 2), :normal)

      breach_window = series([9.5, 9.5, 9.5], step_seconds: 60)
      breach_status = Evaluator.evaluate(rule, breach_window, :trending)

      assert normal_status == :normal
      assert trending_status == :trending
      assert breach_status == :breach

      assert Enum.uniq([normal_status, trending_status, breach_status]) == [
               :normal,
               :trending,
               :breach
             ]
    end

    test "a rule with no rate_of_change_threshold never trends" do
      rule = rule(comparator: :above, boundary_value: 8.0, rate_of_change_threshold: nil)
      window = series([1.0, 7.9], step_seconds: 1)

      assert Evaluator.evaluate(rule, window, :normal) == :normal
    end
  end

  test "an empty window is normal" do
    rule = rule()
    assert Evaluator.evaluate(rule, [], :normal) == :normal
  end
end
