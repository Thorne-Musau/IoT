defmodule Ingestion.Repo.Migrations.AddInventoryFieldsToZonesAndSensors do
  use Ecto.Migration

  def change do
    alter table(:zones) do
      # storage | server_room | entry_point. Only `storage` zones are in
      # FSQ food-safety rule scope (see Ingestion.Inventory.food_safety_scope?/1).
      add :zone_type, :string, null: false, default: "storage"

      # Deliberately nullable and unseeded: which commodity each store holds
      # has not been confirmed by warehouse ops, and guessing it would put an
      # unapproved value in front of the rules engine.
      add :commodity, :string
    end

    alter table(:sensors) do
      # The real Meraki device key. `name` is display-only and NOT unique —
      # Store3-FL legitimately appears twice in WFP Kenya's inventory.
      add :serial, :string
      add :model, :string
      add :position, :string
      add :battery_pct, :integer
      add :rssi_dbm, :integer
      add :notes, :text

      # Meraki-reported device status (e.g. "non_conforming"). An operational
      # /device-health concern, never an environmental food-safety incident.
      add :meraki_status, :string
    end

    create unique_index(:sensors, [:serial])
    create index(:zones, [:zone_type])

    # Enforced at the DB level, not just in the changeset. Split from the
    # `add` above so this migration stays safe against a non-empty table.
    execute "ALTER TABLE sensors ALTER COLUMN serial SET NOT NULL",
            "ALTER TABLE sensors ALTER COLUMN serial DROP NOT NULL"
  end
end
