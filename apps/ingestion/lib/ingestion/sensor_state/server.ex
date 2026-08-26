defmodule Ingestion.SensorState.Server do
  @moduledoc """
  Holds the rolling window of recent readings for a single sensor and runs
  the rules engine and check-in health monitoring against it.

  One of these per sensor, supervised by `Ingestion.SensorState.Supervisor`
  under a `DynamicSupervisor`, so one sensor's crash (a bad reading, a
  timing bug) restarts only that sensor's process and never touches
  another sensor's window or evaluation state.

  Two independent things happen here, both derived from `record/2` calls
  and a periodic self check:

    * **Rule evaluation** (`Ingestion.RulesEngine`) — every recorded
      reading is evaluated against this sensor's commodity's `approved`
      rules. On a status transition (`:normal` <-> `:trending` <->
      `:breach`), `{:rule_evaluation, sensor_id, rule_id, severity,
      prior_status, status}` is broadcast on the `"ingestion:rule_events"`
      topic.
    * **Check-in health** (`Ingestion.HealthMonitor`) — if no reading
      arrives within `check_in_interval_ms`, this sensor is flagged
      `:silent` and `{:sensor_health, sensor_id, gateway_id, :silent}` is
      broadcast on `"ingestion:health"` (and mirrored to
      `Ingestion.HealthMonitor.Tracker` for gateway-level aggregation) —
      an anomaly distinct from an environmental rule breach.
  """

  use GenServer

  alias Ingestion.HealthMonitor.{SensorHealth, Tracker}
  alias Ingestion.RulesEngine

  @typedoc "A single sensor reading."
  @type reading :: %{value: number(), recorded_at: DateTime.t()}

  @default_window_size 50
  @default_check_in_interval_ms :timer.minutes(15)
  @rule_events_topic "ingestion:rule_events"
  @health_topic "ingestion:health"

  defstruct sensor_id: nil,
            commodity: nil,
            gateway_id: nil,
            window: [],
            window_size: @default_window_size,
            check_in_interval_ms: @default_check_in_interval_ms,
            last_seen_at: nil,
            health: :online,
            rule_statuses: %{}

  @type t :: %__MODULE__{
          sensor_id: String.t(),
          commodity: String.t() | nil,
          gateway_id: String.t() | nil,
          window: [reading()],
          window_size: pos_integer(),
          check_in_interval_ms: pos_integer(),
          last_seen_at: DateTime.t() | nil,
          health: SensorHealth.status(),
          rule_statuses: %{integer() => RulesEngine.status()}
        }

  def start_link(opts) do
    sensor_id = Keyword.fetch!(opts, :sensor_id)
    GenServer.start_link(__MODULE__, opts, name: via(sensor_id))
  end

  @doc "Records a new reading into the sensor's rolling window and evaluates it against approved rules."
  @spec record(String.t(), reading()) :: :ok
  def record(sensor_id, %{value: _value, recorded_at: _recorded_at} = reading) do
    GenServer.cast(via(sensor_id), {:record, reading})
  end

  @doc "Returns the current rolling window for a sensor, most recent first."
  @spec window(String.t()) :: [reading()]
  def window(sensor_id) do
    GenServer.call(via(sensor_id), :window)
  end

  @doc "Returns the current per-rule evaluation statuses, `%{rule_id => status}`."
  @spec rule_statuses(String.t()) :: %{integer() => RulesEngine.status()}
  def rule_statuses(sensor_id) do
    GenServer.call(via(sensor_id), :rule_statuses)
  end

  @doc "Returns `:online` or `:silent`, this sensor's own check-in health."
  @spec health(String.t()) :: SensorHealth.status()
  def health(sensor_id) do
    GenServer.call(via(sensor_id), :health)
  end

  defp via(sensor_id) do
    {:via, Registry, {Ingestion.SensorState.Registry, sensor_id}}
  end

  @impl true
  def init(opts) do
    sensor_id = Keyword.fetch!(opts, :sensor_id)
    # Optional: nil means "not in FSQ evaluation scope" (see evaluate_rules/1).
    commodity = Keyword.get(opts, :commodity)
    gateway_id = Keyword.get(opts, :gateway_id)
    window_size = Keyword.get(opts, :window_size, @default_window_size)
    check_in_interval_ms = Keyword.get(opts, :check_in_interval_ms, @default_check_in_interval_ms)

    if gateway_id, do: Tracker.register_sensor(sensor_id, gateway_id)
    schedule_health_check(check_in_interval_ms)

    {:ok,
     %__MODULE__{
       sensor_id: sensor_id,
       commodity: commodity,
       gateway_id: gateway_id,
       window: [],
       window_size: window_size,
       check_in_interval_ms: check_in_interval_ms,
       last_seen_at: DateTime.utc_now()
     }}
  end

  @impl true
  def handle_cast({:record, reading}, state) do
    window = [reading | state.window] |> Enum.take(state.window_size)

    state =
      %{state | window: window, last_seen_at: reading.recorded_at}
      |> mark_online()
      |> evaluate_rules()

    {:noreply, state}
  end

  @impl true
  def handle_call(:window, _from, state), do: {:reply, state.window, state}
  def handle_call(:rule_statuses, _from, state), do: {:reply, state.rule_statuses, state}
  def handle_call(:health, _from, state), do: {:reply, state.health, state}

  @impl true
  def handle_info(:health_check, state) do
    now = DateTime.utc_now()
    status = SensorHealth.status(state.last_seen_at, now, state.check_in_interval_ms)

    state =
      if status != state.health do
        broadcast_health(state.sensor_id, state.gateway_id, status)
        %{state | health: status}
      else
        state
      end

    schedule_health_check(state.check_in_interval_ms)
    {:noreply, state}
  end

  defp mark_online(%__MODULE__{health: :silent} = state) do
    broadcast_health(state.sensor_id, state.gateway_id, :online)
    %{state | health: :online}
  end

  defp mark_online(state), do: state

  # Sensors outside FSQ food-safety scope — the SRV server rooms, the SE
  # entry point, and any storage zone whose commodity warehouse ops has not
  # confirmed yet — have no approved rule set to match against, so rule
  # evaluation is skipped entirely for them. Check-in health monitoring
  # above still runs, so a silent server-room sensor is still reported.
  defp evaluate_rules(%__MODULE__{commodity: nil} = state), do: state

  defp evaluate_rules(state) do
    evaluations =
      RulesEngine.evaluate_commodity(state.commodity, state.window, state.rule_statuses)

    rule_statuses =
      Map.new(evaluations, fn {rule_id, %{status: status}} -> {rule_id, status} end)

    Enum.each(evaluations, fn {rule_id, %{rule: rule, prior_status: prior, status: status}} ->
      if status != prior do
        Phoenix.PubSub.broadcast(
          Ingestion.PubSub,
          @rule_events_topic,
          {:rule_evaluation, state.sensor_id, rule_id, rule.severity, prior, status}
        )
      end
    end)

    %{state | rule_statuses: rule_statuses}
  end

  defp broadcast_health(sensor_id, gateway_id, status) do
    Phoenix.PubSub.broadcast(
      Ingestion.PubSub,
      @health_topic,
      {:sensor_health, sensor_id, gateway_id, status}
    )

    if gateway_id, do: Tracker.report_sensor_status(sensor_id, gateway_id, status)
  end

  defp schedule_health_check(check_in_interval_ms) do
    Process.send_after(self(), :health_check, check_in_interval_ms)
  end
end
