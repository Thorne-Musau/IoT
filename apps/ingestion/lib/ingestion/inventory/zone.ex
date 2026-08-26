defmodule Ingestion.Inventory.Zone do
  @moduledoc """
  A physical area of the warehouse site carrying one or more sensors.

  `zone_type` decides whether the zone is in FSQ food-safety scope:

    * `storage` — a food store. In scope.
    * `server_room` — SRV. Environmental monitoring for IT equipment, not
      food. Out of scope.
    * `entry_point` — SE. Leak/entry monitoring. Out of scope.

  `commodity` is intentionally nullable and left unset by the seeds: which
  commodity each store actually holds has not been confirmed by warehouse
  ops. A zone with a nil commodity has no approved rules to match and is
  simply not evaluated (see `Ingestion.Inventory.evaluable?/1`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @zone_types ~w(storage server_room entry_point)

  schema "zones" do
    field :name, :string
    field :description, :string
    field :zone_type, :string, default: "storage"
    field :commodity, :string

    has_many :sensors, Ingestion.Inventory.Sensor

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(zone, attrs) do
    zone
    |> cast(attrs, [:name, :description, :zone_type, :commodity])
    |> validate_required([:name, :zone_type])
    |> validate_inclusion(:zone_type, @zone_types)
    |> unique_constraint(:name)
  end

  @doc false
  def zone_types, do: @zone_types
end
