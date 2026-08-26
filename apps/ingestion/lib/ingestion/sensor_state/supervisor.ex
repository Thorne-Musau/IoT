defmodule Ingestion.SensorState.Supervisor do
  @moduledoc """
  Supervises one `Ingestion.SensorState.Server` per sensor.

  Sensor servers are started on demand (e.g. on first ingested reading)
  and registered under `Ingestion.SensorState.Registry` so the rules
  engine can route incoming readings to the right process by sensor id.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts (or returns the already-running) rolling-window server for
  `sensor_id`. `opts` must include `:commodity` (matched against
  `threshold_rules.commodity` to find this sensor's approved rules), and
  may include `:gateway_id`, `:window_size`, and `:check_in_interval_ms`.
  """
  @spec start_sensor(String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_sensor(sensor_id, opts \\ []) do
    case DynamicSupervisor.start_child(
           __MODULE__,
           {Ingestion.SensorState.Server, Keyword.put(opts, :sensor_id, sensor_id)}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end
end
