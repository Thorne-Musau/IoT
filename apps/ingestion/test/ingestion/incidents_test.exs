defmodule Ingestion.IncidentsTest do
  use Ingestion.DataCase, async: true

  import Ingestion.Fixtures

  alias Ingestion.Incidents

  describe "the four-state lifecycle" do
    test "runs new -> acknowledged -> monitoring -> closed" do
      incident = insert_incident!()
      assert incident.status == "new"

      {:ok, acknowledged} = Incidents.acknowledge(incident, "j.operator")
      assert acknowledged.status == "acknowledged"
      assert acknowledged.acknowledged_by == "j.operator"
      assert %DateTime{} = acknowledged.acknowledged_at

      {:ok, monitoring} =
        Incidents.record_corrective_action(acknowledged, "Chiller door reseated, unit restarted")

      assert monitoring.status == "monitoring"
      assert monitoring.corrective_action == "Chiller door reseated, unit restarted"

      {:ok, closed} = Incidents.close(monitoring)
      assert closed.status == "closed"
      assert %DateTime{} = closed.resolved_at
    end

    test "acknowledge requires a non-blank actor" do
      incident = insert_incident!()

      assert {:error, :missing_actor} = Incidents.acknowledge(incident, "")
      assert {:error, :missing_actor} = Incidents.acknowledge(incident, "   ")
      assert Incidents.get_incident!(incident.id).status == "new"
    end

    test "corrective action is required to leave the acknowledged state" do
      incident = insert_incident!()
      {:ok, acknowledged} = Incidents.acknowledge(incident, "j.operator")

      assert {:error, :missing_action} = Incidents.record_corrective_action(acknowledged, "")
      assert Incidents.get_incident!(incident.id).status == "acknowledged"
    end

    test "states cannot be skipped" do
      incident = insert_incident!()

      # can't close or record action straight from new
      assert {:error, :invalid_transition} = Incidents.close(incident)
      assert {:error, :invalid_transition} = Incidents.record_corrective_action(incident, "x")

      {:ok, acknowledged} = Incidents.acknowledge(incident, "j.operator")

      # can't acknowledge twice, or close before monitoring
      assert {:error, :invalid_transition} = Incidents.acknowledge(acknowledged, "someone")
      assert {:error, :invalid_transition} = Incidents.close(acknowledged)
    end
  end

  describe "listing" do
    test "open incidents exclude closed ones, and history shows them" do
      open = insert_incident!()
      to_close = insert_incident!()

      {:ok, c} = Incidents.acknowledge(to_close, "j.operator")
      {:ok, c} = Incidents.record_corrective_action(c, "resolved")
      {:ok, closed} = Incidents.close(c)

      open_ids = Incidents.list_open_incidents() |> Enum.map(& &1.id)
      closed_ids = Incidents.list_closed_incidents() |> Enum.map(& &1.id)

      assert open.id in open_ids
      refute closed.id in open_ids
      assert closed.id in closed_ids
    end

    test "preloads rule, sensor and zone so alert content can be built from them" do
      insert_incident!()

      assert [incident] = Incidents.list_open_incidents()
      assert %Ingestion.ThresholdRules.ThresholdRule{} = incident.rule
      assert %Ingestion.Inventory.Sensor{} = incident.sensor
      assert %Ingestion.Inventory.Zone{} = incident.sensor.zone
    end
  end

  describe "escalation windows" do
    test "reads the configured window per severity, not a hardcoded value" do
      assert Incidents.escalation_window_seconds("critical") == 15 * 60
      assert Incidents.escalation_window_seconds("medium") == 60 * 60
    end

    test "falls back to the configured default for an unknown severity" do
      assert Incidents.escalation_window_seconds("nonsense") == 60 * 60
    end

    test "resolves a contact per severity" do
      assert Incidents.escalation_contact("critical") =~ "FSQ"
      assert Incidents.escalation_contact("unknown-severity") == "FSQ duty officer"
    end
  end

  describe "mark_escalated/2" do
    test "escalates once and refuses a second time" do
      incident = insert_incident!()

      assert {:ok, escalated} = Incidents.mark_escalated(incident, "FSQ lead")
      assert %DateTime{} = escalated.escalated_at
      assert escalated.escalated_to == "FSQ lead"

      assert {:error, :already_escalated} = Incidents.mark_escalated(escalated, "FSQ lead")
    end
  end
end
