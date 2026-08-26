defmodule Ingestion.Repo.Migrations.CreateSensors do
  use Ecto.Migration

  def change do
    create table(:sensors) do
      add :zone_id, references(:zones, on_delete: :restrict), null: false
      add :name, :string, null: false
      add :external_id, :string
      add :sensor_type, :string, null: false
      add :unit, :string

      timestamps(type: :utc_datetime)
    end

    create index(:sensors, [:zone_id])
    create unique_index(:sensors, [:external_id])
  end
end
