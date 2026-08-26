defmodule Ingestion.Inventory.Sensor do
  @moduledoc """
  A physical Meraki sensor device.

  Keyed on `serial`, which is unique and required. `name` is **display-only
  and deliberately not unique** — WFP Kenya's real inventory contains two
  distinct devices both named `keMSAsoStore3-FL`
  (`Q3CQ-96DA-V53R` and `Q3CQ-EBP3-FCM5`). That collision is preserved
  as-is rather than renamed; see `docs/sensor-inventory-gaps.md`.

  `battery_pct` and `rssi_dbm` are nullable and mean "not known", which is
  why they are left `nil` rather than `0` for every device whose level was
  not in the Meraki export.

  `serial` doubles as the process-registry key for this sensor's
  `Ingestion.SensorState.Server`, so a rules-engine PubSub event can always
  be resolved back to a real `Sensor` row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "sensors" do
    field :name, :string
    field :serial, :string
    field :model, :string
    field :position, :string
    field :sensor_type, :string
    field :unit, :string
    field :external_id, :string
    field :battery_pct, :integer
    field :rssi_dbm, :integer
    field :notes, :string
    field :meraki_status, :string

    belongs_to :zone, Ingestion.Inventory.Zone

    timestamps(type: :utc_datetime)
  end

  @fields ~w(
    name serial model position sensor_type unit external_id
    battery_pct rssi_dbm notes meraki_status zone_id
  )a

  @doc false
  def changeset(sensor, attrs) do
    sensor
    |> cast(attrs, @fields)
    |> validate_required([:name, :serial, :sensor_type, :zone_id])
    |> validate_number(:battery_pct, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> unique_constraint(:serial)
    |> assoc_constraint(:zone)
  end
end
