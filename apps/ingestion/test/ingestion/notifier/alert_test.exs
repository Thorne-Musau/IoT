defmodule Ingestion.Notifier.AlertTest do
  use Ingestion.DataCase, async: true

  import Ingestion.Fixtures

  alias Ingestion.Notifier.Alert

  defp build_incident(opts \\ []) do
    zone_attrs = Keyword.get(opts, :zone, %{commodity: "frozen_food", name: "Store7"})
    rule_attrs = Keyword.get(opts, :rule, %{})

    zone = insert_zone!(zone_attrs)

    sensor =
      insert_sensor!(
        Map.merge(%{zone: zone, name: "keMSAsoStore7-FL"}, Keyword.get(opts, :sensor, %{}))
      )

    rule =
      insert_approved_rule!(
        Map.merge(
          %{
            commodity: zone.commodity || "frozen_food",
            severity: "critical",
            trigger_condition: "Temperature sustained above the frozen storage ceiling",
            expected_outcome: "Frozen stock begins to thaw; shelf life is compromised",
            recommended_action:
              "Check the chiller door seal and escalate to the cold-chain technician",
            source_reference: "FSQ-SOP-COLD-04"
          },
          rule_attrs
        )
      )

    insert_incident!(%{sensor: sensor, rule: rule, severity: rule.severity})
  end

  describe "content assembled from real records" do
    test "includes zone, commodity, condition, reading, duration, outcome and action" do
      incident = build_incident()
      alert = Alert.build(incident)
      text = Alert.to_text(alert)

      assert alert.zone == "Store7"
      assert alert.commodity == "frozen_food"

      # Every required element, taken from the rule/sensor/zone rather than
      # hand-written copy.
      assert text =~ "Store7"
      assert text =~ "frozen_food"
      assert text =~ "Temperature sustained above the frozen storage ceiling"
      assert text =~ "Frozen stock begins to thaw"
      assert text =~ "Check the chiller door seal"
      assert text =~ "9.5"
      assert text =~ "7m 0s"
      assert text =~ "FSQ-SOP-COLD-04"
    end

    test "includes a link to the incident in the tracking UI" do
      incident = build_incident()
      alert = Alert.build(incident)

      assert alert.url =~ "/incidents/#{incident.id}"
      assert Alert.to_text(alert) =~ alert.url
    end

    test "wording follows the rule — changing the rule changes the alert, with no code change" do
      incident =
        build_incident(
          rule: %{
            expected_outcome: "A COMPLETELY DIFFERENT CONSEQUENCE",
            recommended_action: "A COMPLETELY DIFFERENT REMEDY"
          }
        )

      text = incident |> Alert.build() |> Alert.to_text()

      assert text =~ "A COMPLETELY DIFFERENT CONSEQUENCE"
      assert text =~ "A COMPLETELY DIFFERENT REMEDY"
    end

    test "identifies the sensor by serial as well as name, because names can collide" do
      incident = build_incident()
      alert = Alert.build(incident)

      assert alert.sensor_serial
      assert Alert.to_text(alert) =~ alert.sensor_serial
    end

    test "handles a blank commodity gracefully instead of inventing one" do
      incident = build_incident(zone: %{commodity: nil, name: "Store2"})
      alert = Alert.build(incident)
      text = Alert.to_text(alert)

      assert alert.commodity == nil
      assert text =~ "Commodity: not confirmed"

      # And it certainly must not have made one up.
      refute text =~ "frozen_food"
    end

    test "handles a rule with no expected_outcome or recommended_action without crashing" do
      incident = build_incident(rule: %{expected_outcome: nil, recommended_action: nil})
      text = incident |> Alert.build() |> Alert.to_text()

      assert text =~ "Expected outcome: not recorded on rule"
      assert text =~ "Recommended action: not recorded on rule"
    end

    test "handles a missing reading snapshot without crashing" do
      incident = build_incident()
      incident = %{incident | reading_value: nil, observed_duration_seconds: nil}

      text = incident |> Alert.build() |> Alert.to_text()

      assert text =~ "Current reading: not recorded"
      assert text =~ "Persisted for: not recorded"
    end

    test "the subject carries severity and zone" do
      alert = build_incident() |> Alert.build()

      assert alert.subject =~ "CRITICAL"
      assert alert.subject =~ "Store7"
    end
  end

  describe "escalation alerts" do
    test "are marked as escalations and name the contact" do
      incident = build_incident()
      alert = Alert.build(incident, escalation: "FSQ lead + warehouse manager")
      text = Alert.to_text(alert)

      assert alert.escalation == "FSQ lead + warehouse manager"
      assert alert.subject =~ "ESCALATED"
      assert text =~ "Escalated to: FSQ lead + warehouse manager"
      assert text =~ "Not acknowledged within"

      # Still carries the full context, not just the escalation notice.
      assert text =~ "Store7"
      assert text =~ "Check the chiller door seal"
    end
  end

  describe "channel rendering" do
    test "the Teams payload is an Adaptive Card, not the retired MessageCard format" do
      card = build_incident() |> Alert.build() |> Alert.to_adaptive_card()

      assert card["type"] == "message"
      assert [attachment] = card["attachments"]
      assert attachment["contentType"] == "application/vnd.microsoft.card.adaptive"
      assert attachment["content"]["type"] == "AdaptiveCard"

      # The legacy connector format must not appear anywhere.
      encoded = Jason.encode!(card)
      refute encoded =~ "MessageCard"
      refute encoded =~ "themeColor"
    end

    test "the Adaptive Card carries every content element as facts plus a deep link" do
      alert = build_incident() |> Alert.build()
      card = Alert.to_adaptive_card(alert)

      facts =
        card["attachments"]
        |> hd()
        |> get_in(["content", "body"])
        |> Enum.find(&(&1["type"] == "FactSet"))
        |> Map.fetch!("facts")

      titles = Enum.map(facts, & &1["title"])

      assert "Zone" in titles
      assert "Commodity" in titles
      assert "Condition" in titles
      assert "Current reading" in titles
      assert "Persisted for" in titles
      assert "Expected outcome" in titles
      assert "Recommended action" in titles

      [action] = card["attachments"] |> hd() |> get_in(["content", "actions"])
      assert action["type"] == "Action.OpenUrl"
      assert action["url"] == alert.url
    end

    test "the Graph HTML body escapes content rather than injecting it raw" do
      incident =
        build_incident(rule: %{recommended_action: "Check <script>alert(1)</script> seal"})

      html = incident |> Alert.build() |> Alert.to_html()

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
