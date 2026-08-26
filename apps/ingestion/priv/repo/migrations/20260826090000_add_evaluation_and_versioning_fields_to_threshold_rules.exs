defmodule Ingestion.Repo.Migrations.AddEvaluationAndVersioningFieldsToThresholdRules do
  use Ecto.Migration

  def change do
    alter table(:threshold_rules) do
      # Structured fields the rules engine evaluates against. `trigger_condition`
      # (existing) stays the human-readable description FSQ reviews; these are
      # its machine-evaluable counterpart, filled in alongside it.
      add :comparator, :string, null: false, default: "above"
      add :boundary_value, :float, null: false, default: 0.0
      add :hysteresis_gap, :float, null: false, default: 0.0
      add :rate_of_change_threshold, :float

      # Version-family grouping: every version of "the same" rule shares
      # family_id (set to the first version's own id). Lets version history
      # and "one approved version per family" logic query by family_id
      # instead of walking a linked list.
      add :family_id, references(:threshold_rules, on_delete: :nilify_all)
      add :previous_version_id, references(:threshold_rules, on_delete: :nilify_all)
    end

    create index(:threshold_rules, [:family_id])
  end
end
