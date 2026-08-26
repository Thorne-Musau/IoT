defmodule Ingestion.Inventory do
  @moduledoc """
  Reads over the physical sensor/zone inventory, and the single definition
  of what is in FSQ food-safety scope.

  Food-safety scope is decided here, in one place, so the rules engine, the
  incident pipeline, and the UI cannot disagree about it. Two things put a
  sensor out of scope:

    * its zone is not a `storage` zone (the SRV server rooms and the SE
      entry point monitor equipment and leaks, not food); or
    * its zone has no confirmed `commodity` yet, so there is no approved
      rule set to evaluate it against.

  A sensor being out of food-safety scope does **not** mean it is
  unmonitored: check-in health still runs for every sensor sitewide, so a
  silent server-room sensor is still surfaced as a device-health anomaly.
  """

  import Ecto.Query, warn: false

  alias Ingestion.Inventory.{SeedData, Sensor, Zone}
  alias Ingestion.Repo

  ## Zones

  @doc "Lists all zones, by name."
  @spec list_zones() :: [Zone.t()]
  def list_zones, do: Repo.all(from z in Zone, order_by: z.name)

  @doc "Fetches a zone by name, or nil."
  @spec get_zone_by_name(String.t()) :: Zone.t() | nil
  def get_zone_by_name(name), do: Repo.get_by(Zone, name: name)

  @doc "Lists only the zones in FSQ food-safety scope (`storage` zones)."
  @spec list_food_safety_zones() :: [Zone.t()]
  def list_food_safety_zones do
    Repo.all(from z in Zone, where: z.zone_type == "storage", order_by: z.name)
  end

  ## Sensors

  @doc "Lists all sensors with their zone preloaded, by name."
  @spec list_sensors() :: [Sensor.t()]
  def list_sensors do
    Repo.all(from s in Sensor, order_by: s.name, preload: [:zone])
  end

  @doc "Fetches a sensor by its Meraki serial (the registry key), zone preloaded."
  @spec get_sensor_by_serial(String.t()) :: Sensor.t() | nil
  def get_sensor_by_serial(serial) do
    Repo.one(from s in Sensor, where: s.serial == ^serial, preload: [:zone])
  end

  @doc "Fetches a sensor by id, zone preloaded. Raises if missing."
  @spec get_sensor!(integer()) :: Sensor.t()
  def get_sensor!(id) do
    Repo.one!(from s in Sensor, where: s.id == ^id, preload: [:zone])
  end

  @doc """
  Sensors whose Meraki-reported device status needs operational attention
  (e.g. Store10-RL's `non_conforming`). These are device-health concerns
  and are deliberately never turned into food-safety incidents.
  """
  @spec list_flagged_sensors() :: [Sensor.t()]
  def list_flagged_sensors do
    Repo.all(from s in Sensor, where: not is_nil(s.meraki_status), preload: [:zone])
  end

  ## Scope

  @doc """
  Whether `zone` is in FSQ food-safety scope at all — i.e. it is a food
  store rather than a server room or entry point. Note this is about the
  zone's *purpose*; a storage zone with no confirmed commodity is still in
  scope conceptually but is not yet `evaluable?/1`.
  """
  @spec food_safety_scope?(Zone.t() | Sensor.t() | nil) :: boolean()
  def food_safety_scope?(%Zone{zone_type: "storage"}), do: true
  def food_safety_scope?(%Zone{}), do: false
  def food_safety_scope?(%Sensor{zone: %Zone{} = zone}), do: food_safety_scope?(zone)
  def food_safety_scope?(_), do: false

  @doc """
  Whether the rules engine should evaluate readings for this sensor: it
  must be in food-safety scope *and* its zone must have a confirmed
  commodity to match approved rules against.
  """
  @spec evaluable?(Sensor.t() | Zone.t() | nil) :: boolean()
  def evaluable?(%Sensor{zone: %Zone{} = zone}), do: evaluable?(zone)
  def evaluable?(%Zone{} = zone), do: food_safety_scope?(zone) and present?(zone.commodity)
  def evaluable?(_), do: false

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""

  ## Seeding

  @doc """
  Seeds the real WFP Kenya inventory from `Ingestion.Inventory.SeedData`.

  Idempotent: zones are matched on `name` and sensors on `serial`, so
  re-running updates in place rather than duplicating. Returns
  `{zone_count, sensor_count}`.
  """
  @spec seed_real_inventory!() :: {non_neg_integer(), non_neg_integer()}
  def seed_real_inventory! do
    zones_by_name =
      Map.new(SeedData.zones(), fn attrs ->
        zone =
          case Repo.get_by(Zone, name: attrs.name) do
            nil -> %Zone{}
            existing -> existing
          end
          |> Zone.changeset(attrs)
          |> Repo.insert_or_update!()

        {zone.name, zone}
      end)

    sensors =
      Enum.map(SeedData.sensors(), fn attrs ->
        zone = Map.fetch!(zones_by_name, attrs.zone_name)

        sensor_attrs =
          attrs
          |> Map.delete(:zone_name)
          |> Map.put(:zone_id, zone.id)

        case Repo.get_by(Sensor, serial: attrs.serial) do
          nil -> %Sensor{}
          existing -> existing
        end
        |> Sensor.changeset(sensor_attrs)
        |> Repo.insert_or_update!()
      end)

    {map_size(zones_by_name), length(sensors)}
  end
end
