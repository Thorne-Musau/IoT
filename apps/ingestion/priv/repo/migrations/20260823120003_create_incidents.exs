defmodule Ingestion.Repo.Migrations.CreateIncidents do
  use Ecto.Migration

  def change do
    create table(:incidents) do
      add :sensor_id, references(:sensors, on_delete: :restrict), null: false
      add :rule_id, references(:threshold_rules, on_delete: :restrict), null: false
      add :triggered_at, :utc_datetime, null: false
      add :acknowledged_at, :utc_datetime
      add :acknowledged_by, :string
      add :corrective_action, :text
      add :resolved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:incidents, [:sensor_id])
    create index(:incidents, [:rule_id])
    create index(:incidents, [:triggered_at])
  end
end
