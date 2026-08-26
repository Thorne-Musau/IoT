defmodule Ingestion.Incidents.Monitor do
  @moduledoc """
  Subscribes to the rules engine's broadcasts and turns qualifying
  transitions into persisted `Incident` rows.

  Consumes Phase 2's existing contract unchanged:

      # topic "ingestion:rule_events"
      {:rule_evaluation, sensor_id, rule_id, severity, prior_status, status}

  where `sensor_id` is the sensor's **serial** (its registry key), which is
  how an event is resolved back to a real `Sensor` row.

  ## What qualifies

  Only a transition **into `:breach`** opens an incident. Specifically:

    * `:trending` is a precursor warning, not a breach — it is not an
      incident on its own. An incident is raised if and when the trend
      actually crosses the FSQ-approved boundary.
    * A transition **out of** `:breach` (the hysteresis clear) does not
      close the incident automatically. A human closes incidents, after
      recording what was actually done — the environmental condition
      recovering is not the same as the food-safety event being resolved.
      The clear is recorded in the log for context.
    * A sustained breach re-broadcasting is idempotent: only one open
      incident exists per (sensor, rule) pair, enforced by a partial unique
      index, so duplicates cannot accumulate even under a race.

  Health events (`ingestion:health`) are deliberately **not** turned into
  incidents here. A silent sensor or an offline gateway is a device-health
  anomaly, not a food-safety breach — same reasoning that keeps
  Store10-RL's `non_conforming` status out of the incident stream.
  """

  use GenServer

  require Logger

  alias Ingestion.{Incidents, Inventory, Notifier}
  alias Ingestion.SensorState.Server, as: SensorServer

  @rule_events_topic "ingestion:rule_events"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Ingestion.PubSub, @rule_events_topic)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:rule_evaluation, serial, rule_id, severity, prior, status}, state) do
    handle_evaluation(serial, rule_id, severity, prior, status)
    {:noreply, state}
  end

  # Ignore anything else on the topic rather than crashing the monitor.
  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Processes a single evaluation transition. Exposed so tests can drive it
  synchronously instead of racing a cast.

  Returns `{:ok, incident}` when an incident was opened, `{:ok, :already_open}`
  when one already existed, or `:ignored` for a transition that does not
  qualify.
  """
  @spec handle_evaluation(String.t(), integer(), String.t(), atom(), atom()) ::
          {:ok, Incidents.Incident.t()} | {:ok, :already_open} | :ignored | {:error, term()}
  def handle_evaluation(serial, rule_id, severity, prior, status)

  def handle_evaluation(serial, rule_id, severity, prior, :breach) when prior != :breach do
    case Inventory.get_sensor_by_serial(serial) do
      nil ->
        Logger.warning(
          "incident monitor: rule event for unknown sensor serial #{inspect(serial)} — ignoring"
        )

        {:error, :unknown_sensor}

      sensor ->
        open_incident(sensor, rule_id, severity)
    end
  end

  def handle_evaluation(serial, rule_id, _severity, :breach, cleared) do
    # The condition recovered. Left open for a human to close, deliberately.
    Logger.info(
      "incident monitor: sensor #{serial} rule #{rule_id} cleared to #{inspect(cleared)}; " <>
        "any open incident stays open until closed by an operator."
    )

    :ignored
  end

  def handle_evaluation(_serial, _rule_id, _severity, _prior, _status), do: :ignored

  defp open_incident(sensor, rule_id, severity) do
    {reading_value, observed_duration} = snapshot_reading(sensor.serial)

    attrs = %{
      sensor_id: sensor.id,
      rule_id: rule_id,
      severity: severity,
      status: "new",
      trigger_status: "breach",
      triggered_at: DateTime.utc_now() |> DateTime.truncate(:second),
      reading_value: reading_value,
      observed_duration_seconds: observed_duration
    }

    case Incidents.create_incident(attrs) do
      {:ok, incident} ->
        Notifier.notify_new_incident(incident)
        {:ok, incident}

      {:error, :already_open} ->
        {:ok, :already_open}

      {:error, reason} ->
        Logger.error(
          "incident monitor: failed to open incident for #{sensor.serial}/#{rule_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Snapshots the sensor's current reading and how long the window has been
  # running, so the alert can quote both. The PubSub event itself carries
  # neither, and the live GenServer is the only place that knows them.
  #
  # Best-effort by design: the sensor process may legitimately not be running
  # (a test driving the monitor directly, or a restart between broadcast and
  # handling), and a missing reading must not stop the incident being recorded.
  defp snapshot_reading(serial) do
    case SensorServer.window(serial) do
      [%{value: value} = newest | rest] ->
        duration =
          case List.last(rest) do
            nil -> 0
            oldest -> DateTime.diff(newest.recorded_at, oldest.recorded_at)
          end

        {value / 1, duration}

      _ ->
        {nil, nil}
    end
  catch
    :exit, _reason -> {nil, nil}
  end
end
