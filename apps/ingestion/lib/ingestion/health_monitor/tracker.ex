defmodule Ingestion.HealthMonitor.Tracker do
  @moduledoc """
  Aggregates per-sensor health into per-gateway health.

  Each `Ingestion.SensorState.Server` registers itself here on start (so
  every known sensor is accounted for, even ones that have never gone
  silent) and casts an update whenever its own health transitions between
  `:online` and `:silent`. Whenever that changes a gateway's computed
  status (`Ingestion.HealthMonitor.GatewayHealth.status/2`), this process
  broadcasts `{:gateway_health, gateway_id, status}` on the
  `"ingestion:health"` `Ingestion.PubSub` topic — a "gateway offline"
  anomaly, distinguishable from the individual `{:sensor_health, ...}`
  "sensor silent" anomalies each server broadcasts on its own.
  """

  use GenServer

  alias Ingestion.HealthMonitor.GatewayHealth

  @topic "ingestion:health"

  defstruct sensor_statuses: %{}, gateway_statuses: %{}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers `sensor_id` as belonging to `gateway_id`, defaulting its status to `:online`."
  @spec register_sensor(String.t(), String.t()) :: :ok
  def register_sensor(sensor_id, gateway_id) do
    GenServer.cast(__MODULE__, {:register_sensor, sensor_id, gateway_id})
  end

  @doc "Reports `sensor_id` (on `gateway_id`)'s current health status."
  @spec report_sensor_status(String.t(), String.t(), :online | :silent) :: :ok
  def report_sensor_status(sensor_id, gateway_id, status) do
    GenServer.cast(__MODULE__, {:sensor_status, sensor_id, gateway_id, status})
  end

  @doc "Synchronously reads back the currently-computed status for `gateway_id` (defaults to `:online`)."
  @spec gateway_status(String.t()) :: GatewayHealth.status()
  def gateway_status(gateway_id) do
    GenServer.call(__MODULE__, {:gateway_status, gateway_id})
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_cast({:register_sensor, sensor_id, gateway_id}, state) do
    {:noreply, put_sensor_status(state, gateway_id, sensor_id, :online)}
  end

  @impl true
  def handle_cast({:sensor_status, sensor_id, gateway_id, status}, state) do
    {:noreply, put_sensor_status(state, gateway_id, sensor_id, status)}
  end

  @impl true
  def handle_call({:gateway_status, gateway_id}, _from, state) do
    {:reply, Map.get(state.gateway_statuses, gateway_id, :online), state}
  end

  defp put_sensor_status(state, gateway_id, sensor_id, status) do
    sensor_statuses =
      Map.update(
        state.sensor_statuses,
        gateway_id,
        %{sensor_id => status},
        &Map.put(&1, sensor_id, status)
      )

    state = %{state | sensor_statuses: sensor_statuses}
    new_gateway_status = GatewayHealth.status(Map.fetch!(sensor_statuses, gateway_id))
    prior_gateway_status = Map.get(state.gateway_statuses, gateway_id, :online)

    if new_gateway_status != prior_gateway_status do
      Phoenix.PubSub.broadcast(
        Ingestion.PubSub,
        @topic,
        {:gateway_health, gateway_id, new_gateway_status}
      )
    end

    %{state | gateway_statuses: Map.put(state.gateway_statuses, gateway_id, new_gateway_status)}
  end
end
