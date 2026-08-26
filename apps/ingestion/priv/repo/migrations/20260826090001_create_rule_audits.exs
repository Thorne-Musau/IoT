defmodule Ingestion.Repo.Migrations.CreateRuleAudits do
  use Ecto.Migration

  def change do
    create table(:rule_audits) do
      add :rule_id, references(:threshold_rules, on_delete: :delete_all), null: false
      add :action, :string, null: false
      add :from_status, :string
      add :to_status, :string, null: false
      add :actor, :string, null: false
      add :comment, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:rule_audits, [:rule_id])
    create index(:rule_audits, [:inserted_at])
  end
end
