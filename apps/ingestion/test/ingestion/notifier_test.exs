defmodule Ingestion.NotifierTest do
  use Ingestion.DataCase, async: false

  import Ingestion.Fixtures

  alias Ingestion.Notifier
  alias Ingestion.Notifier.Alert

  setup do
    Notifier.Local.subscribe()
    :ok
  end

  defp build_incident do
    zone = insert_zone!(%{name: "Store4", commodity: "chilled_dairy"})
    sensor = insert_sensor!(%{zone: zone, name: "keMSAsoStore4-RR"})

    rule =
      insert_approved_rule!(%{
        commodity: "chilled_dairy",
        severity: "critical",
        trigger_condition: "Temperature sustained above the chilled storage ceiling",
        expected_outcome: "Dairy stock spoils and must be condemned",
        recommended_action: "Move stock to Store5 and call the cold-chain technician"
      })

    insert_incident!(%{sensor: sensor, rule: rule, severity: "critical"})
  end

  describe "Local is the implementation everywhere in test" do
    test "impl/0 returns Local" do
      assert Notifier.impl() == Notifier.Local
    end

    test "impl/0 refuses to return Live even when config explicitly asks for it" do
      original = Application.get_env(:ingestion, :notifier)

      try do
        Application.put_env(:ingestion, :notifier, Notifier.Live)

        # Two independent guards: config pins Local, and this hard floor
        # catches a misconfiguration. Under Mix.env() == :test the floor wins.
        assert Notifier.impl() == Notifier.Local
      after
        Application.put_env(:ingestion, :notifier, original)
      end
    end
  end

  describe "notify_new_incident/1" do
    test "delivers to both channels with fully-assembled content" do
      incident = build_incident()

      assert {:ok, %Alert{}} = Notifier.notify_new_incident(incident)

      assert_receive {:notification_delivered, :outlook, outlook_alert, text}, 1_000
      assert_receive {:notification_delivered, :teams, teams_alert, card}, 1_000

      # Both channels describe the same incident, from the same records.
      assert outlook_alert.incident_id == incident.id
      assert teams_alert.incident_id == incident.id

      # Outlook: rendered mail body carries every required element.
      assert text =~ "Store4"
      assert text =~ "chilled_dairy"
      assert text =~ "Temperature sustained above the chilled storage ceiling"
      assert text =~ "Dairy stock spoils"
      assert text =~ "Move stock to Store5"
      assert text =~ "/incidents/#{incident.id}"

      # Teams: the real Adaptive Card payload, not a stub.
      assert card["attachments"] |> hd() |> Map.fetch!("contentType") =~ "adaptive"
      encoded = Jason.encode!(card)
      assert encoded =~ "Store4"
      assert encoded =~ "Move stock to Store5"
    end

    test "stamps notified_at on the incident" do
      incident = build_incident()
      assert incident.notified_at == nil

      Notifier.notify_new_incident(incident)

      assert %DateTime{} = Ingestion.Incidents.get_incident!(incident.id).notified_at
    end
  end

  describe "notify_escalation/2" do
    test "delivers an escalation notice to both channels" do
      incident = build_incident()

      assert {:ok, alert} = Notifier.notify_escalation(incident, "FSQ lead + warehouse manager")
      assert alert.escalation == "FSQ lead + warehouse manager"

      assert_receive {:notification_delivered, :outlook, _alert, text}, 1_000
      assert_receive {:notification_delivered, :teams, _alert, _card}, 1_000

      assert text =~ "ESCALATED"
      assert text =~ "FSQ lead + warehouse manager"
    end
  end

  describe "channel isolation" do
    test "one channel failing does not stop the other" do
      defmodule HalfBrokenNotifier do
        @behaviour Ingestion.Notifier

        @impl true
        def deliver(:outlook, _alert), do: raise("simulated Graph outage")

        @impl true
        def deliver(:teams, alert) do
          Phoenix.PubSub.broadcast(
            Ingestion.PubSub,
            Ingestion.Notifier.Local.topic(),
            {:notification_delivered, :teams, alert, :ok}
          )

          :ok
        end
      end

      original = Application.get_env(:ingestion, :notifier)

      try do
        Application.put_env(:ingestion, :notifier, HalfBrokenNotifier)
        alert = build_incident() |> Alert.build()

        # Must not raise, despite the outlook channel blowing up.
        assert :ok = Notifier.deliver_all(alert)

        # Teams still got through.
        assert_receive {:notification_delivered, :teams, _alert, :ok}, 1_000
      after
        Application.put_env(:ingestion, :notifier, original)
      end
    end
  end
end
