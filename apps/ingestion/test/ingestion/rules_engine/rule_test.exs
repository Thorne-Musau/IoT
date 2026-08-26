defmodule Ingestion.RulesEngine.RuleTest do
  use ExUnit.Case, async: true

  import Ingestion.Fixtures

  alias Ingestion.RulesEngine.Rule

  describe "from_schema!/1" do
    test "builds a Rule from an approved threshold rule" do
      schema = unsaved_threshold_rule("approved")

      assert %Rule{id: id, comparator: :above} = Rule.from_schema!(schema)
      assert id == schema.id
    end

    for status <- ["draft", "pending_fsq_review", "retired"] do
      test "raises for a #{status} threshold rule" do
        schema = unsaved_threshold_rule(unquote(status))

        assert_raise ArgumentError, ~r/#{unquote(status)}/, fn ->
          Rule.from_schema!(schema)
        end
      end
    end
  end

  describe "raise_boundary/1 and clear_boundary/1" do
    test "an 'above' rule's raise boundary is exactly boundary_value; clear is stricter (lower)" do
      rule = rule(comparator: :above, boundary_value: 8.0, hysteresis_gap: 1.0)

      assert Rule.raise_boundary(rule) == 8.0
      assert Rule.clear_boundary(rule) == 7.0
    end

    test "a 'below' rule's raise boundary is exactly boundary_value; clear is stricter (higher)" do
      rule = rule(comparator: :below, boundary_value: 2.0, hysteresis_gap: 0.5)

      assert Rule.raise_boundary(rule) == 2.0
      assert Rule.clear_boundary(rule) == 2.5
    end
  end

  describe "breached_at?/3 and cleared_at?/3" do
    test "raise is inclusive at the boundary; clear is inclusive at the clear boundary ('above' rule)" do
      rule = rule(comparator: :above, boundary_value: 8.0, hysteresis_gap: 1.0)

      assert Rule.breached_at?(rule, 8.0, Rule.raise_boundary(rule))
      refute Rule.breached_at?(rule, 7.9, Rule.raise_boundary(rule))

      assert Rule.cleared_at?(rule, 7.0, Rule.clear_boundary(rule))
      refute Rule.cleared_at?(rule, 7.1, Rule.clear_boundary(rule))
    end

    test "raise is inclusive at the boundary; clear is inclusive at the clear boundary ('below' rule)" do
      rule = rule(comparator: :below, boundary_value: 2.0, hysteresis_gap: 0.5)

      assert Rule.breached_at?(rule, 2.0, Rule.raise_boundary(rule))
      refute Rule.breached_at?(rule, 2.1, Rule.raise_boundary(rule))

      assert Rule.cleared_at?(rule, 2.5, Rule.clear_boundary(rule))
      refute Rule.cleared_at?(rule, 2.4, Rule.clear_boundary(rule))
    end
  end
end
