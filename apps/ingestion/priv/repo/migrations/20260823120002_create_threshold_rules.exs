defmodule Ingestion.Repo.Migrations.CreateThresholdRules do
  use Ecto.Migration

  def change do
    create table(:threshold_rules) do
      add :commodity, :string, null: false
      add :trigger_condition, :text, null: false
      add :duration_window, :integer, null: false
      add :severity, :string, null: false
      add :expected_outcome, :text
      add :recommended_action, :text
      add :source_reference, :string
      add :status, :string, null: false, default: "draft"
      add :approved_by, :string
      add :approved_at, :utc_datetime
      add :version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create index(:threshold_rules, [:status])
    create index(:threshold_rules, [:commodity])
  end
end
