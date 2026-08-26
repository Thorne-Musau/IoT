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

  A transition **into `:breach`** opens a full incident, at the rule's own
  severity. A transition **into `:trending`, from `:normal`,** opens an
  *advisory* incident — same schema, same `Incidents`/`Notifier` pipeline,
  just `severity: "advisory"` and `trigger_status: "trending"` instead of
  the rule's severity and `"breach"`. Advisory incidents notify exactly
  like breach incidents (see `Ingestion.Notifier.Alert`, which renders
  them as a developing trend rather than a confirmed breach) and escalate
  on the much longer `"advisory"` window (`config :ingestion, :escalation`
  — 4 hours by default), never the breach-tier windows.

  Specifically:

    * `:trending` only opens an incident on genuine entry from `:normal`.
      A sustained trend re-broadcasting nothing (the sensor server only
      broadcasts on a status *change*) never re-fires this; an advisory
      that oscillates normal -> trending -> normal -> trending is
      idempotent the same way a sustained breach is (see below).
    * `:trending -> :normal` (the trend receding without ever breaching —
      a false alarm) does **not** notify. It is logged for context and the
      advisory incident, if still open, is left open for a human to close,
      same as a breach clearing.
    * A transition **out of** `:breach` (the hysteresis clear) does not
      close the incident automatically, for the same reason. The clear is
      recorded in the log for context.
    * Re-broadcasting is idempotent **per trigger_status**: at most one
      open incident exists per (sensor, rule, trigger_status), enforced by
      a partial unique index — so an already-open advisory does not block
      a subsequent breach on the same sensor/rule from opening its own
      incident, and vice versa.

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
    with_sensor(serial, fn sensor -> open_incident(sensor, rule_id, severity, "breach") end)
  end

  def handle_evaluation(serial, rule_id, _severity, :normal, :trending) do
    with_sensor(serial, fn sensor -> open_incident(sensor, rule_id, "advisory", "trending") end)
  end

  def handle_evaluation(serial, rule_id, _severity, :breach, cleared) do
    # The condition recovered. Left open for a human to close, deliberately.
    Logger.info(
      "incident monitor: sensor #{serial} rule #{rule_id} cleared to #{inspect(cleared)}; " <>
        "any open incident stays open until closed by an operator."
    )

    :ignored
  end

  def handle_evaluation(serial, rule_id, _severity, :trending, :normal) do
    # The trend receded before ever crossing the boundary — a false alarm.
    # No second notification; any open advisory is left for a human to close.
    Logger.info(
      "incident monitor: sensor #{serial} rule #{rule_id} trend cleared back to :normal " <>
        "without breaching — no notification sent."
    )

    :ignored
  end

  def handle_evaluation(_serial, _rule_id, _severity, _prior, _status), do: :ignored

  defp with_sensor(serial, fun) do
    case Inventory.get_sensor_by_serial(serial) do
      nil ->
        Logger.warning(
          "incident monitor: rule event for unknown sensor serial #{inspect(serial)} — ignoring"
        )

        {:error, :unknown_sensor}

      sensor ->
        fun.(sensor)
    end
  end

  defp open_incident(sensor, rule_id, severity, trigger_status) do
    {reading_value, observed_duration} = snapshot_reading(sensor.serial)

    attrs = %{
      sensor_id: sensor.id,
      rule_id: rule_id,
      severity: severity,
      status: "new",
      trigger_status: trigger_status,
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
          "incident monitor: failed to open #{trigger_status} incident for " <>
            "#{sensor.serial}/#{rule_id}: #{inspect(reason)}"
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
