defmodule Ingestion.Repo.Migrations.SplitOpenIncidentUniquenessByTriggerStatus do
  use Ecto.Migration

  def change do
    drop index(:incidents, [:sensor_id, :rule_id],
           name: :incidents_one_open_per_sensor_rule,
           where: "status != 'closed'"
         )

    # An advisory (:trending) incident and a full breach incident can now be
    # open for the same sensor/rule pair at once — a breach doesn't have to
    # wait for an existing advisory to be closed first. Uniqueness is still
    # enforced per trigger_status, so a re-broadcast of either stays
    # idempotent within its own tier.
    create unique_index(:incidents, [:sensor_id, :rule_id, :trigger_status],
             where: "status != 'closed'",
             name: :incidents_one_open_per_sensor_rule_trigger
           )
  end
end
