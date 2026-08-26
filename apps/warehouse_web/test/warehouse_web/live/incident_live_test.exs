defmodule WarehouseWeb.IncidentLiveTest do
  use WarehouseWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ingestion.Fixtures

  alias Ingestion.Incidents

  defp incident_with_context(attrs \\ %{}) do
    # Zone names are genuinely unique in the schema, so each call needs its own.
    {zone_name, attrs} = Map.pop(attrs, :zone_name, "Store6")

    zone = insert_zone!(%{name: zone_name, commodity: "frozen_food"})
    sensor = insert_sensor!(%{zone: zone, name: "keMSAsoStore6-RL"})

    rule =
      insert_approved_rule!(%{
        commodity: "frozen_food",
        severity: "critical",
        trigger_condition: "Temperature sustained above the frozen storage ceiling",
        expected_outcome: "Frozen stock begins to thaw",
        recommended_action: "Check the chiller door seal"
      })

    insert_incident!(Map.merge(%{sensor: sensor, rule: rule, severity: "critical"}, attrs))
  end

  describe "the incident list" do
    test "shows an open incident with its zone, severity and status", %{conn: conn} do
      incident = incident_with_context()

      {:ok, _view, html} = live(conn, ~p"/incidents")

      assert html =~ "Incidents"
      assert html =~ "Store6"
      assert html =~ "critical"
      assert html =~ "New / Notified"
      assert html =~ "bg-danger-100"
      assert html =~ "keMSAsoStore6-RL"
      assert html =~ "#{incident.id}"
    end

    test "shows an empty state when there is nothing open", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/incidents")
      assert html =~ "No open incidents"
    end

    test "shows 'not confirmed' rather than inventing a commodity", %{conn: conn} do
      zone = insert_zone!(%{name: "Store8", commodity: nil})
      sensor = insert_sensor!(%{zone: zone})
      rule = insert_approved_rule!(%{commodity: "frozen_food"})
      incident_with_no_commodity = insert_incident!(%{sensor: sensor, rule: rule})

      {:ok, _view, html} = live(conn, ~p"/incidents")

      assert html =~ "#{incident_with_no_commodity.id}"
      assert html =~ "not confirmed"
    end

    test "the history tab separates closed incidents from open ones", %{conn: conn} do
      open = incident_with_context()
      to_close = incident_with_context(%{zone_name: "Store9"})

      {:ok, c} = Incidents.acknowledge(to_close, "j.operator")
      {:ok, c} = Incidents.record_corrective_action(c, "Reseated door")
      {:ok, closed} = Incidents.close(c)

      {:ok, view, html} = live(conn, ~p"/incidents")

      assert html =~ "incident-#{open.id}"
      refute html =~ "incident-#{closed.id}\""

      history = render_click(view, "switch_tab", %{"tab" => "history"})
      assert history =~ "closed-incident-#{closed.id}"
    end
  end

  describe "the incident detail page" do
    test "shows the full context assembled from the rule and sensor records", %{conn: conn} do
      incident = incident_with_context()

      {:ok, _view, html} = live(conn, ~p"/incidents/#{incident.id}")

      assert html =~ "Store6"
      assert html =~ "frozen_food"
      assert html =~ "keMSAsoStore6-RL"
      assert html =~ "Temperature sustained above the frozen storage ceiling"
      assert html =~ "Frozen stock begins to thaw"
      assert html =~ "Check the chiller door seal"
      assert html =~ "9.5"
      assert html =~ "7m 0s"
    end

    test "shows the escalation state when an incident has been escalated", %{conn: conn} do
      incident = incident_with_context()
      {:ok, escalated} = Incidents.mark_escalated(incident, "FSQ lead + warehouse manager")

      {:ok, _view, html} = live(conn, ~p"/incidents/#{escalated.id}")

      assert html =~ "Escalated"
      assert html =~ "FSQ lead + warehouse manager"
    end
  end

  describe "the full lifecycle, driven through the UI" do
    test "takes an incident from New through Acknowledged, Monitoring and Closed", %{conn: conn} do
      incident = incident_with_context()

      {:ok, view, html} = live(conn, ~p"/incidents/#{incident.id}")
      assert html =~ "New / Notified"

      # New -> Acknowledged
      html = render_submit(view, "acknowledge", %{"actor" => "j.operator"})
      assert html =~ "Acknowledged / In action"
      assert html =~ "j.operator"
      assert Incidents.get_incident!(incident.id).status == "acknowledged"

      # Acknowledged -> Monitoring, logging the corrective action
      html =
        render_submit(view, "record_action", %{
          "corrective_action" => "Reseated the chiller door and restarted the unit"
        })

      assert html =~ "Monitoring"
      assert html =~ "Reseated the chiller door and restarted the unit"

      reloaded = Incidents.get_incident!(incident.id)
      assert reloaded.status == "monitoring"
      assert reloaded.corrective_action == "Reseated the chiller door and restarted the unit"

      # Monitoring -> Closed
      html = render_click(view, "close")
      assert html =~ "Closed"
      assert html =~ "bg-success-100"

      closed = Incidents.get_incident!(incident.id)
      assert closed.status == "closed"
      assert %DateTime{} = closed.resolved_at
    end

    test "acknowledging with a blank name is refused", %{conn: conn} do
      incident = incident_with_context()
      {:ok, view, _html} = live(conn, ~p"/incidents/#{incident.id}")

      html = render_submit(view, "acknowledge", %{"actor" => "   "})

      assert html =~ "Enter your name"
      assert Incidents.get_incident!(incident.id).status == "new"
    end

    test "moving on without describing the corrective action is refused", %{conn: conn} do
      incident = incident_with_context()
      {:ok, acknowledged} = Incidents.acknowledge(incident, "j.operator")

      {:ok, view, _html} = live(conn, ~p"/incidents/#{acknowledged.id}")

      html = render_submit(view, "record_action", %{"corrective_action" => ""})

      assert html =~ "Describe the corrective action"
      assert Incidents.get_incident!(incident.id).status == "acknowledged"
    end

    test "only the next valid action is offered for each status", %{conn: conn} do
      incident = incident_with_context()

      # new: acknowledge only
      {:ok, _view, html} = live(conn, ~p"/incidents/#{incident.id}")
      assert html =~ ~s(phx-submit="acknowledge")
      refute html =~ ~s(phx-submit="record_action")
      refute html =~ ~s(phx-click="close")

      # acknowledged: record action only
      {:ok, acknowledged} = Incidents.acknowledge(incident, "j.operator")
      {:ok, _view, html} = live(conn, ~p"/incidents/#{acknowledged.id}")
      assert html =~ ~s(phx-submit="record_action")
      refute html =~ ~s(phx-submit="acknowledge")
      refute html =~ ~s(phx-click="close")

      # monitoring: close only
      {:ok, monitoring} = Incidents.record_corrective_action(acknowledged, "Reseated door")
      {:ok, _view, html} = live(conn, ~p"/incidents/#{monitoring.id}")
      assert html =~ ~s(phx-click="close")
      refute html =~ ~s(phx-submit="acknowledge")
      refute html =~ ~s(phx-submit="record_action")
    end
  end
end
