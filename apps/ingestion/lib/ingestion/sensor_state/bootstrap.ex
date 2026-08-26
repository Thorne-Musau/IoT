defmodule Ingestion.SensorState.Bootstrap do
  @moduledoc """
  Starts one `Ingestion.SensorState.Server` per real `Sensor` record.

  This replaces Phase 2's ad hoc runtime parameters: instead of a caller
  inventing a `sensor_id`/`commodity`/`gateway_id`, every sensor process is
  now derived from the seeded inventory. Each server is registered under its
  Sensor's **serial**, which is unique and not null, so a
  `{:rule_evaluation, sensor_id, ...}` PubSub event can always be resolved
  back to a real `Sensor` row (see `Ingestion.Incidents.Monitor`).

  Each server receives:

    * `sensor_id` — the Sensor's `serial` (registry key)
    * `commodity` — the zone's commodity, or `nil` when the zone is out of
      FSQ scope or its commodity is unconfirmed. `nil` disables rule
      evaluation for that sensor while leaving check-in health monitoring
      active.
    * `gateway_id` — the zone name, which is the granularity at which
      "these sensors went silent together" actually indicates a shared
      network/power failure.

  Runs on boot only when `:start_sensor_servers` is enabled for the app,
  which is off in test so the suite controls its own processes.
  """

  require Logger

  alias Ingestion.Inventory
  alias Ingestion.SensorState.Supervisor, as: SensorSupervisor

  @doc """
  Starts a server for every seeded sensor. Returns the number started.
  Safe to call repeatedly — `start_sensor/2` treats an already-running
  sensor as success.
  """
  @spec start_all() :: non_neg_integer()
  def start_all do
    Inventory.list_sensors()
    |> Enum.reduce(0, fn sensor, started ->
      case start_sensor(sensor) do
        {:ok, _pid} ->
          started + 1

        {:error, reason} ->
          Logger.warning("could not start sensor server for #{sensor.serial}: #{inspect(reason)}")

          started
      end
    end)
  end

  @doc "Starts (or returns the already-running) server for one `Sensor` record."
  @spec start_sensor(Inventory.Sensor.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_sensor(sensor, extra_opts \\ []) do
    opts =
      Keyword.merge(
        [
          commodity: evaluable_commodity(sensor),
          gateway_id: sensor.zone && sensor.zone.name
        ],
        extra_opts
      )

    SensorSupervisor.start_sensor(sensor.serial, opts)
  end

  # Only hand the engine a commodity when the sensor is genuinely in scope.
  # A server-room sensor whose zone somehow had a commodity set must still
  # not be evaluated against food-safety rules.
  defp evaluable_commodity(sensor) do
    if Inventory.evaluable?(sensor), do: sensor.zone.commodity
  end
end
