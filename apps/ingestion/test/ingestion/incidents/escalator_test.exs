defmodule Ingestion.Incidents.EscalatorTest do
  use Ingestion.DataCase, async: false

  import Ingestion.Fixtures

  alias Ingestion.Incidents
  alias Ingestion.Incidents.Escalator
  alias Ingestion.Notifier

  setup do
    Notifier.Local.subscribe()
    :ok
  end

  # Escalation is asserted by moving `now` forward rather than sleeping, so
  # the window boundary is tested exactly and the suite stays fast.
  defp seconds_from_now(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp critical_incident do
    insert_incident!(%{severity: "critical"})
  end

  defp advisory_incident do
    insert_incident!(%{severity: "advisory", trigger_status: "trending"})
  end

  describe "the severity window" do
    test "does not escalate before the window has elapsed" do
      incident = critical_incident()
      window = Incidents.escalation_window_seconds("critical")

      # One second short of the 15-minute critical window.
      assert Escalator.run_once(seconds_from_now(window - 1)) == []

      assert Incidents.get_incident!(incident.id).escalated_at == nil
      refute_receive {:notification_delivered, _channel, _alert, _rendered}, 200
    end

    test "escalates once the window has elapsed" do
      incident = critical_incident()
      window = Incidents.escalation_window_seconds("critical")

      assert [escalated] = Escalator.run_once(seconds_from_now(window))

      assert escalated.id == incident.id
      assert %DateTime{} = escalated.escalated_at
      assert escalated.escalated_to == "FSQ lead + warehouse manager"
    end

    test "uses each severity's own window, not one global value" do
      critical = insert_incident!(%{severity: "critical"})
      medium = insert_incident!(%{severity: "medium"})

      # 15 minutes in: critical is due, medium (60 minutes) is not.
      assert [escalated] = Escalator.run_once(seconds_from_now(15 * 60))
      assert escalated.id == critical.id

      assert Incidents.get_incident!(medium.id).escalated_at == nil

      # An hour in, medium is due too.
      assert [escalated_medium] = Escalator.run_once(seconds_from_now(60 * 60))
      assert escalated_medium.id == medium.id
    end
  end

  describe "advisory incidents use their own, much longer window" do
    test "an advisory does not escalate on the critical (15 min) window" do
      advisory_incident()

      assert Escalator.run_once(seconds_from_now(15 * 60)) == []
      refute_receive {:notification_delivered, _channel, _alert, _rendered}, 200
    end

    test "an advisory does not escalate even at the longest breach-tier window (low, 2h)" do
      advisory_incident()

      # low severity's window (2h) is still short of advisory's (4h+).
      low_window = Incidents.escalation_window_seconds("low")
      advisory_window = Incidents.escalation_window_seconds("advisory")
      assert advisory_window > low_window

      assert Escalator.run_once(seconds_from_now(low_window)) == []
    end

    test "an advisory escalates once its own window has elapsed, at least 4 hours" do
      incident = advisory_incident()
      window = Incidents.escalation_window_seconds("advisory")

      assert window >= 4 * 60 * 60

      assert [escalated] = Escalator.run_once(seconds_from_now(window))
      assert escalated.id == incident.id
      assert %DateTime{} = escalated.escalated_at

      assert_receive {:notification_delivered, :outlook, alert, text}, 1_000
      assert alert.severity == "advisory"
      assert text =~ "ESCALATED"
    end

    test "a critical and an advisory incident escalate independently, on their own clocks" do
      critical = critical_incident()
      advisory = advisory_incident()

      # 15 minutes in: only the critical one is due.
      assert [escalated] = Escalator.run_once(seconds_from_now(15 * 60))
      assert escalated.id == critical.id
      assert Incidents.get_incident!(advisory.id).escalated_at == nil

      # Once the advisory's own window has passed, it escalates too —
      # without touching the critical incident (already escalated, and not
      # re-escalated).
      assert [escalated_advisory] =
               Escalator.run_once(
                 seconds_from_now(Incidents.escalation_window_seconds("advisory"))
               )

      assert escalated_advisory.id == advisory.id
    end
  end

  describe "acknowledgement stops escalation" do
    test "an incident acknowledged within its window never escalates" do
      incident = critical_incident()
      window = Incidents.escalation_window_seconds("critical")

      {:ok, _acknowledged} = Incidents.acknowledge(incident, "j.operator")

      # Well past the window — still must not escalate, because someone took it.
      assert Escalator.run_once(seconds_from_now(window * 10)) == []
      assert Incidents.get_incident!(incident.id).escalated_at == nil
    end

    test "incidents further along the lifecycle are never escalated either" do
      incident = critical_incident()
      {:ok, acknowledged} = Incidents.acknowledge(incident, "j.operator")
      {:ok, _monitoring} = Incidents.record_corrective_action(acknowledged, "Door reseated")

      assert Escalator.run_once(seconds_from_now(10 * 60 * 60)) == []
    end
  end

  describe "escalating exactly once" do
    test "a still-unacknowledged incident is not re-escalated on later ticks" do
      incident = critical_incident()
      window = Incidents.escalation_window_seconds("critical")

      assert [escalated] = Escalator.run_once(seconds_from_now(window))
      first_escalated_at = escalated.escalated_at

      # Several more ticks, long after the window.
      assert Escalator.run_once(seconds_from_now(window * 2)) == []
      assert Escalator.run_once(seconds_from_now(window * 3)) == []

      reloaded = Incidents.get_incident!(incident.id)
      assert reloaded.escalated_at == first_escalated_at
    end
  end

  describe "escalation notification" do
    test "notifies both channels with the escalation contact and full context" do
      critical_incident()
      window = Incidents.escalation_window_seconds("critical")

      assert [_escalated] = Escalator.run_once(seconds_from_now(window))

      assert_receive {:notification_delivered, :outlook, alert, text}, 1_000
      assert_receive {:notification_delivered, :teams, _alert, _card}, 1_000

      assert alert.escalation == "FSQ lead + warehouse manager"
      assert text =~ "ESCALATED"
      assert text =~ "FSQ lead + warehouse manager"
      assert text =~ "Not acknowledged within"
    end
  end

  describe "escalation_due?/2" do
    test "is false for anything not still in `new`" do
      incident = critical_incident()
      {:ok, acknowledged} = Incidents.acknowledge(incident, "j.operator")

      refute Incidents.escalation_due?(acknowledged, seconds_from_now(10_000))
    end

    test "is false for an already-escalated incident" do
      incident = critical_incident()
      {:ok, escalated} = Incidents.mark_escalated(incident, "FSQ lead")

      refute Incidents.escalation_due?(escalated, seconds_from_now(10_000))
    end
  end
end
