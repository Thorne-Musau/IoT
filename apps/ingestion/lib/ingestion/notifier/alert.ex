defmodule Ingestion.Notifier.Alert do
  @moduledoc """
  Assembles alert content for an incident.

  **All copy here is derived from real records** — the triggering
  `ThresholdRule`'s own fields and the `Sensor`/`Zone` it fired on. Nothing
  in this module hand-writes a threshold, a consequence, or a remedy: those
  come from the rule's FSQ-approved `trigger_condition`, `expected_outcome`
  and `recommended_action`. If FSQ changes the approved wording, the alerts
  change with it, with no code edit.

  Every alert states, per the concept paper:

    * the zone and its commodity (gracefully blank when warehouse ops has
      not confirmed the commodity yet — never invented)
    * the condition and the current reading
    * how long the condition has persisted
    * the rule's `expected_outcome` — what happens to the stock if ignored
    * the rule's `recommended_action` — what to do about it
    * a link to the incident in the tracking UI

  `build/1` returns a channel-neutral struct; `Ingestion.Notifier.Local`,
  the Graph mail body and the Teams Adaptive Card all render from it, so
  the three channels cannot drift apart in what they say.

  An incident whose `trigger_status` is `"trending"` (an advisory — a
  developing trend, not yet a confirmed breach) goes through this exact
  same pipeline. Its subject reads "ADVISORY: ..." instead of the severity,
  and it carries one extra "Status" line framing it as a developing trend
  — everything else (condition, reading, duration, expected outcome,
  recommended action, link) is identical to a breach alert, still pulled
  from the same rule and sensor/zone records.
  """

  alias Ingestion.Incidents.Incident

  @enforce_keys [:incident_id, :subject, :severity, :zone, :lines, :url]
  defstruct [
    :incident_id,
    :subject,
    :severity,
    :zone,
    :commodity,
    :sensor_name,
    :sensor_serial,
    :condition,
    :reading,
    :duration,
    :expected_outcome,
    :recommended_action,
    :source_reference,
    :lines,
    :url,
    :escalation
  ]

  @type t :: %__MODULE__{}

  @unconfirmed "not confirmed"
  @not_recorded "not recorded"

  @doc """
  Builds alert content for `incident`. The incident must have `:rule` and
  `sensor: :zone` preloaded (everything from `Ingestion.Incidents` does).

  Pass `escalation: contact` to render this as an escalation notice rather
  than a first alert.
  """
  @spec build(Incident.t(), keyword()) :: t()
  def build(%Incident{} = incident, opts \\ []) do
    escalation = Keyword.get(opts, :escalation)

    rule = incident.rule
    sensor = incident.sensor
    zone = sensor && sensor.zone

    zone_name = (zone && zone.name) || "unknown zone"
    commodity = present(zone && zone.commodity)
    condition = present(rule && rule.trigger_condition) || "condition not recorded on rule"
    reading = format_reading(incident, sensor)
    duration = format_duration(incident)
    expected_outcome = present(rule && rule.expected_outcome)
    recommended_action = present(rule && rule.recommended_action)

    advisory? = incident.trigger_status == "trending"

    subject =
      cond do
        escalation ->
          "ESCALATED (#{String.upcase(incident.severity)}): #{zone_name} — unacknowledged for #{duration_since_trigger(incident)}"

        advisory? ->
          "ADVISORY: #{zone_name} — trending toward #{condition_summary(condition)}"

        true ->
          "#{String.upcase(incident.severity)}: #{zone_name} — #{condition_summary(condition)}"
      end

    lines =
      [
        {"Zone", zone_name},
        {"Commodity", commodity || @unconfirmed},
        {"Sensor", sensor_label(sensor)},
        {"Condition", condition},
        {"Current reading", reading},
        {"Persisted for", duration},
        {"Expected outcome", expected_outcome || "not recorded on rule"},
        {"Recommended action", recommended_action || "not recorded on rule"}
      ]
      |> maybe_prepend_advisory_status(advisory?)
      |> maybe_append_source(rule)
      |> maybe_append_escalation(escalation, incident)

    %__MODULE__{
      incident_id: incident.id,
      subject: subject,
      severity: incident.severity,
      zone: zone_name,
      commodity: commodity,
      sensor_name: sensor && sensor.name,
      sensor_serial: sensor && sensor.serial,
      condition: condition,
      reading: reading,
      duration: duration,
      expected_outcome: expected_outcome,
      recommended_action: recommended_action,
      source_reference: present(rule && rule.source_reference),
      lines: lines,
      url: incident_url(incident),
      escalation: escalation
    }
  end

  @doc "Renders the alert as plain text — used by the Local notifier and as the Graph mail fallback."
  @spec to_text(t()) :: String.t()
  def to_text(%__MODULE__{} = alert) do
    body =
      alert.lines
      |> Enum.map_join("\n", fn {label, value} -> "#{label}: #{value}" end)

    """
    #{alert.subject}

    #{body}

    View incident: #{alert.url}
    """
  end

  @doc "Renders the alert as the HTML body of a Graph email."
  @spec to_html(t()) :: String.t()
  def to_html(%__MODULE__{} = alert) do
    rows =
      alert.lines
      |> Enum.map_join("", fn {label, value} ->
        "<tr><th align=\"left\" style=\"padding:4px 12px 4px 0;vertical-align:top\">#{escape(label)}</th>" <>
          "<td style=\"padding:4px 0\">#{escape(value)}</td></tr>"
      end)

    """
    <html><body style="font-family:sans-serif">
    <h2>#{escape(alert.subject)}</h2>
    <table>#{rows}</table>
    <p><a href="#{escape(alert.url)}">View incident ##{alert.incident_id}</a></p>
    </body></html>
    """
  end

  @doc """
  Renders the alert as a Teams **Adaptive Card**, wrapped for a Power
  Automate Workflow webhook. The retired Incoming Webhook connector's
  `MessageCard` format is deliberately not used — it no longer works.
  """
  @spec to_adaptive_card(t()) :: map()
  def to_adaptive_card(%__MODULE__{} = alert) do
    facts =
      Enum.map(alert.lines, fn {label, value} -> %{"title" => label, "value" => value} end)

    %{
      "type" => "message",
      "attachments" => [
        %{
          "contentType" => "application/vnd.microsoft.card.adaptive",
          "contentUrl" => nil,
          "content" => %{
            "$schema" => "http://adaptivecards.io/schemas/adaptive-card.json",
            "type" => "AdaptiveCard",
            "version" => "1.4",
            "body" => [
              %{
                "type" => "TextBlock",
                "size" => "Large",
                "weight" => "Bolder",
                "wrap" => true,
                "color" => card_colour(alert.severity),
                "text" => alert.subject
              },
              %{"type" => "FactSet", "facts" => facts}
            ],
            "actions" => [
              %{
                "type" => "Action.OpenUrl",
                "title" => "View incident ##{alert.incident_id}",
                "url" => alert.url
              }
            ]
          }
        }
      ]
    }
  end

  ## Content helpers

  defp sensor_label(nil), do: @not_recorded

  defp sensor_label(sensor) do
    # Serial is always included: Store3-FL is a genuinely ambiguous display
    # name (two devices share it), so the name alone cannot identify which
    # device fired. See docs/sensor-inventory-gaps.md.
    position = present(sensor.position)
    base = "#{sensor.name} (#{sensor.serial})"
    if position, do: "#{base} — position #{position}", else: base
  end

  defp format_reading(%Incident{reading_value: nil}, _sensor), do: @not_recorded

  defp format_reading(%Incident{reading_value: value}, sensor) do
    unit = sensor && present(sensor.unit)
    formatted = value |> Float.round(2) |> to_string()
    if unit, do: "#{formatted} #{unit}", else: formatted
  end

  defp format_duration(%Incident{observed_duration_seconds: nil}), do: @not_recorded

  defp format_duration(%Incident{observed_duration_seconds: seconds}),
    do: humanize_seconds(seconds)

  defp duration_since_trigger(%Incident{triggered_at: nil}), do: @not_recorded

  defp duration_since_trigger(%Incident{triggered_at: triggered_at}) do
    DateTime.utc_now() |> DateTime.diff(triggered_at, :second) |> humanize_seconds()
  end

  @doc false
  def humanize_seconds(seconds) when seconds < 60, do: "#{seconds}s"

  def humanize_seconds(seconds) when seconds < 3600 do
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  def humanize_seconds(seconds) do
    "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
  end

  defp condition_summary(condition) do
    condition |> String.split("\n") |> List.first() |> truncate(120)
  end

  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: String.slice(text, 0, max) <> "…"

  # Advisories carry the same Condition/Expected outcome/Recommended action
  # lines as a breach (all pulled from the same rule, unchanged) — this is
  # the one extra line that frames it as a developing trend rather than a
  # confirmed breach. Breach alerts are untouched: this only fires for
  # trigger_status == "trending".
  defp maybe_prepend_advisory_status(lines, false), do: lines

  defp maybe_prepend_advisory_status(lines, true) do
    [{"Status", "Developing trend — has not yet crossed the FSQ-approved boundary"} | lines]
  end

  defp maybe_append_source(lines, rule) do
    case present(rule && rule.source_reference) do
      nil -> lines
      reference -> lines ++ [{"Source reference", reference}]
    end
  end

  defp maybe_append_escalation(lines, nil, _incident), do: lines

  defp maybe_append_escalation(lines, contact, incident) do
    lines ++
      [
        {"Escalated to", contact},
        {"Reason", "Not acknowledged within the #{escalation_window_label(incident)} window"}
      ]
  end

  defp escalation_window_label(incident) do
    Ingestion.Incidents.escalation_window_seconds(incident.severity) |> humanize_seconds()
  end

  defp incident_url(incident) do
    base =
      Application.get_env(:ingestion, :incident_url_base, "http://localhost:4000/incidents")
      |> String.trim_trailing("/")

    "#{base}/#{incident.id}"
  end

  defp card_colour("critical"), do: "Attention"
  defp card_colour("high"), do: "Warning"
  defp card_colour("advisory"), do: "Accent"
  defp card_colour(_), do: "Default"

  defp present(nil), do: nil

  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp present(value), do: value

  # Local, dependency-free HTML escaping: `apps/ingestion` has no Phoenix.HTML
  # dependency and should not grow one just to build a mail body.
  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
