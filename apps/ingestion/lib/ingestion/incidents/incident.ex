defmodule Ingestion.Incidents.Incident do
  @moduledoc """
  A food-safety incident raised by the rules engine against a real sensor
  and a real approved threshold rule.

  Status model — exactly the four states from the concept paper:

      new -> acknowledged -> monitoring -> closed
       │         │              │
       └─────────┴──────────────┴──> (closed is terminal)

    * `new` — raised and notified, nobody has picked it up yet. This is the
      state the escalation timer watches.
    * `acknowledged` — somebody has taken it and is acting on it.
    * `monitoring` — corrective action taken, watching to confirm it held.
    * `closed` — resolved.

  `severity` is copied from the triggering rule at creation time rather
  than read live, so an incident's escalation window does not shift under
  it if the rule is later versioned — **except** for a `:trending`
  transition, which always opens the incident at the fixed `"advisory"`
  severity regardless of the rule's own severity (see
  `Ingestion.Incidents.Monitor`). `trigger_status` (`"breach"` or
  `"trending"`) records which one raised it.

  A sensor/rule pair can have at most one open incident *per
  trigger_status* at a time (`incidents_one_open_per_sensor_rule_trigger`)
  — so an open advisory does not block a subsequent breach from raising
  its own incident, and vice versa.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(new acknowledged monitoring closed)
  @open_statuses ~w(new acknowledged monitoring)

  schema "incidents" do
    field :status, :string, default: "new"
    field :severity, :string
    field :trigger_status, :string, default: "breach"

    field :triggered_at, :utc_datetime
    field :acknowledged_at, :utc_datetime
    field :acknowledged_by, :string
    field :corrective_action, :string
    field :resolved_at, :utc_datetime

    field :escalated_at, :utc_datetime
    field :escalated_to, :string
    field :notified_at, :utc_datetime

    # What the engine actually saw when it raised, snapshotted so alert
    # copy can quote the reading and its persistence without re-reading a
    # live GenServer that may since have moved on or restarted.
    field :reading_value, :float
    field :observed_duration_seconds, :integer

    belongs_to :sensor, Ingestion.Inventory.Sensor
    belongs_to :rule, Ingestion.ThresholdRules.ThresholdRule

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(incident, attrs) do
    incident
    |> cast(attrs, [
      :sensor_id,
      :rule_id,
      :status,
      :severity,
      :trigger_status,
      :triggered_at,
      :reading_value,
      :observed_duration_seconds,
      :notified_at
    ])
    |> validate_required([:sensor_id, :rule_id, :severity, :triggered_at])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:sensor)
    |> assoc_constraint(:rule)
    |> unique_constraint([:sensor_id, :rule_id, :trigger_status],
      name: :incidents_one_open_per_sensor_rule_trigger,
      message: "already has an open incident"
    )
  end

  @doc false
  def statuses, do: @statuses

  @doc false
  def open_statuses, do: @open_statuses
end
