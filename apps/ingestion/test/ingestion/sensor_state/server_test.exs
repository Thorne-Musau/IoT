defmodule Ingestion.SensorState.ServerTest do
  use Ingestion.DataCase, async: true

  import Ingestion.Fixtures

  alias Ingestion.SensorState.{Server, Supervisor}

  setup do
    Phoenix.PubSub.subscribe(Ingestion.PubSub, "ingestion:rule_events")
    Phoenix.PubSub.subscribe(Ingestion.PubSub, "ingestion:health")
    :ok
  end

  defp start_sensor!(sensor_id, opts) do
    {:ok, pid} = Supervisor.start_sensor(sensor_id, opts)
    Ecto.Adapters.SQL.Sandbox.allow(Ingestion.Repo, self(), pid)

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(Supervisor, pid)
    end)

    pid
  end

  describe "rule evaluation" do
    test "recording a sustained breach broadcasts a rule_evaluation transition" do
      commodity = "server_test_frozen_#{System.unique_integer([:positive])}"
      sensor_id = "sensor-#{System.unique_integer([:positive])}"

      rule =
        insert_approved_rule!(%{
          commodity: commodity,
          boundary_value: 8.0,
          hysteresis_gap: 0.0,
          duration_window: 0,
          severity: "critical"
        })

      start_sensor!(sensor_id, commodity: commodity)

      Server.record(sensor_id, %{value: 9.5, recorded_at: DateTime.utc_now()})

      assert_receive {:rule_evaluation, ^sensor_id, rule_id, "critical", :normal, :breach}, 500
      assert rule_id == rule.id
      assert Server.rule_statuses(sensor_id) == %{rule.id => :breach}
    end

    test "a breach anomaly is distinct from a sensor-silent anomaly on the same sensor" do
      commodity = "server_test_frozen_#{System.unique_integer([:positive])}"
      sensor_id = "sensor-#{System.unique_integer([:positive])}"

      insert_approved_rule!(%{
        commodity: commodity,
        boundary_value: 8.0,
        hysteresis_gap: 0.0,
        duration_window: 0
      })

      start_sensor!(sensor_id, commodity: commodity, check_in_interval_ms: 50)

      Server.record(sensor_id, %{value: 9.5, recorded_at: DateTime.utc_now()})
      assert_receive {:rule_evaluation, ^sensor_id, _rule_id, _severity, :normal, :breach}, 500

      # no further readings arrive -> the sensor itself goes silent, a
      # different anomaly than the environmental breach above
      assert_receive {:sensor_health, ^sensor_id, nil, :silent}, 500
    end

    test "a non-approved rule in the sensor's commodity is never evaluated" do
      commodity = "server_test_frozen_#{System.unique_integer([:positive])}"
      sensor_id = "sensor-#{System.unique_integer([:positive])}"

      insert_draft_rule!(%{
        commodity: commodity,
        boundary_value: 8.0,
        hysteresis_gap: 0.0,
        duration_window: 0
      })

      start_sensor!(sensor_id, commodity: commodity)
      Server.record(sensor_id, %{value: 9.5, recorded_at: DateTime.utc_now()})

      refute_receive {:rule_evaluation, ^sensor_id, _, _, _, _}, 300
      assert Server.rule_statuses(sensor_id) == %{}
    end
  end

  describe "sensor health" do
    test "a missed check-in produces a distinct sensor-silent anomaly" do
      commodity = "server_test_health_#{System.unique_integer([:positive])}"
      sensor_id = "sensor-#{System.unique_integer([:positive])}"

      start_sensor!(sensor_id, commodity: commodity, check_in_interval_ms: 50)

      assert Server.health(sensor_id) == :online
      assert_receive {:sensor_health, ^sensor_id, nil, :silent}, 500
      assert Server.health(sensor_id) == :silent
    end

    test "recording again after going silent flips the sensor back online" do
      commodity = "server_test_health_#{System.unique_integer([:positive])}"
      sensor_id = "sensor-#{System.unique_integer([:positive])}"

      start_sensor!(sensor_id, commodity: commodity, check_in_interval_ms: 50)
      assert_receive {:sensor_health, ^sensor_id, nil, :silent}, 500

      Server.record(sensor_id, %{value: 1.0, recorded_at: DateTime.utc_now()})
      assert_receive {:sensor_health, ^sensor_id, nil, :online}, 500
      assert Server.health(sensor_id) == :online
    end
  end

  describe "gateway health" do
    test "one silent sensor on a gateway does not mark the gateway offline, but all of them together do" do
      gateway_id = "gateway-#{System.unique_integer([:positive])}"
      commodity = "server_test_gateway_#{System.unique_integer([:positive])}"

      sensor_a = "sensor-#{System.unique_integer([:positive])}"
      sensor_b = "sensor-#{System.unique_integer([:positive])}"

      # NB: `setup` already subscribes to "ingestion:health". Subscribing a
      # second time here would deliver every broadcast twice, and the
      # duplicate of sensor_a's :silent would then be matched where
      # sensor_b's is expected below.

      # staggered intervals so sensor_a is reliably observed silent well
      # before sensor_b, instead of racing to silence together
      start_sensor!(sensor_a,
        commodity: commodity,
        gateway_id: gateway_id,
        check_in_interval_ms: 50
      )

      start_sensor!(sensor_b,
        commodity: commodity,
        gateway_id: gateway_id,
        check_in_interval_ms: 400
      )

      # Generous timeouts: a health check that lands exactly on its interval
      # boundary reads as still-online and waits a full interval more, so
      # under load sensor_b can legitimately take up to ~2x its interval to
      # report silent. The ordering being asserted still holds either way.
      assert_receive {:sensor_health, ^sensor_a, ^gateway_id, :silent}, 2_000
      refute_receive {:gateway_health, ^gateway_id, :offline}, 150

      assert_receive {:sensor_health, ^sensor_b, ^gateway_id, :silent}, 2_000
      assert_receive {:gateway_health, ^gateway_id, :offline}, 2_000

      assert Ingestion.HealthMonitor.Tracker.gateway_status(gateway_id) == :offline
    end
  end
end
