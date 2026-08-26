defmodule Ingestion.Repo.Migrations.AddWorkflowFieldsToIncidents do
  use Ecto.Migration

  def change do
    alter table(:incidents) do
      # The four-state model from the concept paper:
      # new -> acknowledged -> monitoring -> closed
      add :status, :string, null: false, default: "new"

      # Copied from the triggering rule at creation time, so an incident's
      # severity (and therefore its escalation window) stays stable even if
      # the rule is later versioned.
      add :severity, :string, null: false, default: "medium"

      add :escalated_at, :utc_datetime
      add :escalated_to, :string

      # Snapshot of what the engine saw when it raised, so alert content can
      # state the actual reading and how long it had persisted without having
      # to re-interrogate a live GenServer later.
      add :reading_value, :float
      add :observed_duration_seconds, :integer

      # Which engine status raised this: "breach" or "trending".
      add :trigger_status, :string, null: false, default: "breach"

      add :notified_at, :utc_datetime
    end

    create index(:incidents, [:status])
    create index(:incidents, [:severity])
    create index(:incidents, [:escalated_at])

    # One open incident per (sensor, rule) pair at a time: a sustained breach
    # that keeps re-broadcasting must not pile up duplicate rows. Enforced in
    # the DB so it holds even if two events race.
    create unique_index(:incidents, [:sensor_id, :rule_id],
             where: "status != 'closed'",
             name: :incidents_one_open_per_sensor_rule
           )
  end
end
