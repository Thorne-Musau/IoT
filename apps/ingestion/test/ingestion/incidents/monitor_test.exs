defmodule Ingestion.Incidents.MonitorTest do
  use Ingestion.DataCase, async: true

  import Ingestion.Fixtures

  alias Ingestion.Incidents
  alias Ingestion.Incidents.Monitor
  alias Ingestion.Notifier

  setup do
    zone = insert_zone!(%{commodity: "frozen_food"})
    sensor = insert_sensor!(%{zone: zone, name: "keTestStore-FL"})
    rule = insert_approved_rule!(%{commodity: "frozen_food", severity: "critical"})

    %{zone: zone, sensor: sensor, rule: rule}
  end

  describe "a transition into :breach" do
    test "persists exactly one incident with the right sensor and rule", ctx do
      assert {:ok, incident} =
               Monitor.handle_evaluation(
                 ctx.sensor.serial,
                 ctx.rule.id,
                 "critical",
                 :normal,
                 :breach
               )

      assert incident.sensor_id == ctx.sensor.id
      assert incident.rule_id == ctx.rule.id
      assert incident.status == "new"
      assert incident.severity == "critical"
      assert incident.trigger_status == "breach"
      assert %DateTime{} = incident.triggered_at

      assert length(Incidents.list_open_incidents()) == 1
    end

    test "is idempotent — a re-broadcast of a sustained breach does not open a second incident",
         ctx do
      assert {:ok, first} =
               Monitor.handle_evaluation(
                 ctx.sensor.serial,
                 ctx.rule.id,
                 "critical",
                 :normal,
                 :breach
               )

      assert {:ok, :already_open} =
               Monitor.handle_evaluation(
                 ctx.sensor.serial,
                 ctx.rule.id,
                 "critical",
                 :trending,
                 :breach
               )

      assert [only] = Incidents.list_open_incidents()
      assert only.id == first.id
    end

    test "opens a fresh incident once the previous one has been closed", ctx do
      {:ok, first} =
        Monitor.handle_evaluation(ctx.sensor.serial, ctx.rule.id, "critical", :normal, :breach)

      {:ok, first} = Incidents.acknowledge(first, "j.operator")
      {:ok, first} = Incidents.record_corrective_action(first, "Door reseated")
      {:ok, _closed} = Incidents.close(first)

      assert {:ok, second} =
               Monitor.handle_evaluation(
                 ctx.sensor.serial,
                 ctx.rule.id,
                 "critical",
                 :normal,
                 :breach
               )

      refute second.id == first.id
      assert length(Incidents.list_open_incidents()) == 1
    end

    test "records an unknown serial as an error instead of crashing", ctx do
      assert {:error, :unknown_sensor} =
               Monitor.handle_evaluation(
                 "NOT-A-REAL-SERIAL",
                 ctx.rule.id,
                 "critical",
                 :normal,
                 :breach
               )

      assert Incidents.list_open_incidents() == []
    end
  end

  describe "a transition into :trending from :normal (advisory)" do
    setup do
      Notifier.Local.subscribe()
      :ok
    end

    test "persists an advisory-severity incident, distinct from the rule's own severity", ctx do
      assert {:ok, incident} =
               Monitor.handle_evaluation(
                 ctx.sensor.serial,
                 ctx.rule.id,
                 "critical",
                 :normal,
                 :trending
               )

      assert incident.sensor_id == ctx.sensor.id
      assert incident.rule_id == ctx.rule.id
      assert incident.status == "new"
      assert incident.severity == "advisory"
      assert incident.trigger_status == "trending"
      assert %DateTime{} = incident.triggered_at

      assert length(Incidents.list_open_incidents()) == 1
    end

    test "notifies exactly once via both channels, through the same Notifier pipeline", ctx do
      assert {:ok, _incident} =
               Monitor.handle_evaluation(
                 ctx.sensor.serial,
                 ctx.rule.id,
                 "critical",
                 :normal,
                 :trending
               )

      assert_receive {:notification_delivered, :outlook, alert, _rendered}, 1_000
      assert_receive {:notification_delivered, :teams, _alert, _rendered}, 1_000
      refute_receive {:notification_delivered, _channel, _alert, _rendered}, 200

      assert alert.severity == "advisory"
    end

    test "is idempotent — re-entering :trending while one is already open does not double-notify",
         ctx do
      assert {:ok, first} =
               Monitor.handle_evaluation(
                 ctx.sensor.serial,
                 ctx.rule.id,
                 "critical",
                 :normal,
                 :trending
               )

      assert_receive {:notification_delivered, :outlook, _alert, _rendered}, 1_000
      assert_receive {:notification_delivered, :teams, _alert, _rendered}, 1_000

      assert {:ok, :already_open} =
               Monitor.handle_evaluation(
                 ctx.sensor.serial,
                 ctx.rule.id,
                 "critical",
                 :normal,
                 :trending
               )

      refute_receive {:notification_delivered, _channel, _alert, _rendered}, 200
      assert [only] = Incidents.list_open_incidents()
      assert only.id == first.id
    end

    test "does not block, and is not blocked by, a subsequent full breach on the same sensor/rule",
         ctx do
      assert {:ok, advisory} =
               Monitor.handle_evaluation(
                 ctx.sensor.serial,
                 ctx.rule.id,
                 "critical",
                 :normal,
                 :trending
               )

      assert_receive {:notification_delivered, :outlook, _alert, _rendered}, 1_000
      assert_receive {:notification_delivered, :teams, _alert, _rendered}, 1_000

      assert {:ok, breach} =
               Monitor.handle_evaluation(
                 ctx.sensor.serial,
                 ctx.rule.id,
                 "critical",
                 :trending,
                 :breach
               )

      assert_receive {:notification_delivered, :outlook, breach_alert, _rendered}, 1_000
      assert_receive {:notification_delivered, :teams, _alert, _rendered}, 1_000

      refute breach.id == advisory.id
      assert breach.severity == "critical"
      assert breach.trigger_status == "breach"
      assert breach_alert.severity == "critical"

      open_ids = Incidents.list_open_incidents() |> Enum.map(& &1.id) |> Enum.sort()
      assert open_ids == Enum.sort([advisory.id, breach.id])
    end
  end

  describe "transitions that must NOT create an incident" do
    setup do
      Notifier.Local.subscribe()
      :ok
    end

    test "returning to :normal from :trending (a false alarm) creates and notifies nothing",
         ctx do
      assert :ignored =
               Monitor.handle_evaluation(
                 ctx.sensor.serial,
                 ctx.rule.id,
                 "critical",
                 :trending,
                 :normal
               )

      assert Incidents.list_open_incidents() == []
      refute_receive {:notification_delivered, _channel, _alert, _rendered}, 200
    end

    test "a false alarm does not re-notify even when the advisory it followed is still open",
         ctx do
      assert {:ok, advisory} =
               Monitor.handle_evaluation(
                 ctx.sensor.serial,
                 ctx.rule.id,
                 "critical",
                 :normal,
                 :trending
               )

      assert_receive {:notification_delivered, :outlook, _alert, _rendered}, 1_000
      assert_receive {:notification_delivered, :teams, _alert, _rendered}, 1_000

      assert :ignored =
               Monitor.handle_evaluation(
                 ctx.sensor.serial,
                 ctx.rule.id,
                 "critical",
                 :trending,
                 :normal
               )

      refute_receive {:notification_delivered, _channel, _alert, _rendered}, 200

      # left open for a human to close, same as a breach clearing
      reloaded = Incidents.get_incident!(advisory.id)
      assert reloaded.status == "new"
    end

    test "a breach clearing does not auto-close the incident — a human does that", ctx do
      {:ok, incident} =
        Monitor.handle_evaluation(ctx.sensor.serial, ctx.rule.id, "critical", :normal, :breach)

      assert_receive {:notification_delivered, :outlook, _alert, _rendered}, 1_000
      assert_receive {:notification_delivered, :teams, _alert, _rendered}, 1_000

      assert :ignored =
               Monitor.handle_evaluation(
                 ctx.sensor.serial,
                 ctx.rule.id,
                 "critical",
                 :breach,
                 :normal
               )

      refute_receive {:notification_delivered, _channel, _alert, _rendered}, 200

      reloaded = Incidents.get_incident!(incident.id)
      assert reloaded.status == "new"
      assert reloaded.resolved_at == nil
    end
  end

  describe "the running GenServer" do
    test "turns a real PubSub broadcast into a persisted incident", ctx do
      # A named Monitor is already supervised; start an isolated one so this
      # test owns the DB connection it uses.
      {:ok, monitor} = Monitor.start_link(name: :"monitor_#{System.unique_integer([:positive])}")
      Ecto.Adapters.SQL.Sandbox.allow(Ingestion.Repo, self(), monitor)

      Phoenix.PubSub.subscribe(Ingestion.PubSub, Incidents.topic())

      send(
        monitor,
        {:rule_evaluation, ctx.sensor.serial, ctx.rule.id, "critical", :normal, :breach}
      )

      # The incidents topic is global, so other async tests broadcast on it
      # too — match on this test's own sensor rather than the first message.
      sensor_id = ctx.sensor.id
      assert_receive {:incident_opened, %{sensor_id: ^sensor_id} = incident}, 1_000
      assert incident.rule_id == ctx.rule.id
    end
  end
end
