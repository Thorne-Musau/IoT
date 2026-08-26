defmodule WarehouseWeb.IncidentComponents do
  @moduledoc """
  Shared presentation for incidents, so the list and the detail page label
  and colour things identically.

  Colour mapping follows `docs/design-tokens.md`:

    * severity — `danger` for critical, `warning` for high, `neutral`
      otherwise
    * status — `danger` for new (needs attention), `warning` for
      acknowledged/monitoring (in hand), `success` for closed
  """

  use Phoenix.Component
  use WarehouseWeb, :verified_routes

  @doc "A compact summary card for one incident, linking to its detail page."
  attr :incident, :map, required: true

  def incident_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-border bg-card p-4">
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <.severity_badge severity={@incident.severity} />
            <.status_badge status={@incident.status} />
            <.escalated_badge :if={@incident.escalated_at} to={@incident.escalated_to} />
            <span class="text-sm font-semibold text-card-foreground">
              {zone_name(@incident)}
            </span>
            <span class="text-xs text-muted-foreground">#{@incident.id}</span>
          </div>

          <p class="mt-1 text-sm text-card-foreground">{condition(@incident)}</p>

          <p class="mt-1 text-xs text-muted-foreground">
            {sensor_label(@incident)} · commodity: {commodity(@incident)} · triggered {format_datetime(
              @incident.triggered_at
            )}
          </p>
        </div>

        <.link
          navigate={~p"/incidents/#{@incident.id}"}
          class="shrink-0 rounded-md border border-border px-3 py-1.5 text-xs font-semibold text-card-foreground hover:bg-muted"
        >
          View
        </.link>
      </div>
    </div>
    """
  end

  attr :severity, :string, required: true

  def severity_badge(assigns) do
    ~H"""
    <span class={[
      "rounded-md px-2 py-0.5 text-xs font-semibold uppercase tracking-wide",
      severity_class(@severity)
    ]}>
      {@severity}
    </span>
    """
  end

  attr :status, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "rounded-md px-2 py-0.5 text-xs font-semibold uppercase tracking-wide",
      status_class(@status)
    ]}>
      {status_label(@status)}
    </span>
    """
  end

  attr :to, :string, default: nil

  def escalated_badge(assigns) do
    ~H"""
    <span class="rounded-md bg-danger-100 px-2 py-0.5 text-xs font-semibold uppercase tracking-wide text-danger-700">
      Escalated{if @to, do: " → #{@to}"}
    </span>
    """
  end

  ## Presentation helpers, shared with the LiveViews

  def severity_class("critical"), do: "bg-danger-100 text-danger-700"
  def severity_class("high"), do: "bg-warning-100 text-warning-700"
  def severity_class(_), do: "bg-neutral-100 text-neutral-700"

  def status_class("new"), do: "bg-danger-100 text-danger-700"
  def status_class("acknowledged"), do: "bg-warning-100 text-warning-700"
  def status_class("monitoring"), do: "bg-warning-100 text-warning-700"
  def status_class("closed"), do: "bg-success-100 text-success-700"
  def status_class(_), do: "bg-neutral-100 text-neutral-700"

  def status_label("new"), do: "New / Notified"
  def status_label("acknowledged"), do: "Acknowledged / In action"
  def status_label("monitoring"), do: "Monitoring"
  def status_label("closed"), do: "Closed"
  def status_label(other), do: other

  def zone_name(%{sensor: %{zone: %{name: name}}}), do: name
  def zone_name(_), do: "unknown zone"

  @doc "Commodity, or an explicit 'not confirmed' — never invented."
  def commodity(%{sensor: %{zone: %{commodity: commodity}}})
      when is_binary(commodity) and commodity != "",
      do: commodity

  def commodity(_), do: "not confirmed"

  def condition(%{rule: %{trigger_condition: condition}})
      when is_binary(condition) and condition != "",
      do: condition

  def condition(_), do: "Condition not recorded on the triggering rule"

  @doc """
  Sensor name plus serial. The serial is always shown because display names
  are not unique — two Store3-FL devices share one name (see
  `docs/sensor-inventory-gaps.md`), so the name alone is ambiguous.
  """
  def sensor_label(%{sensor: %{name: name, serial: serial}}), do: "#{name} (#{serial})"
  def sensor_label(_), do: "unknown sensor"

  def format_datetime(nil), do: "—"
  def format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  def format_reading(%{reading_value: nil}), do: "not recorded"

  def format_reading(%{reading_value: value} = incident) do
    formatted = value |> Float.round(2) |> to_string()

    case incident do
      %{sensor: %{unit: unit}} when is_binary(unit) and unit != "" -> "#{formatted} #{unit}"
      _ -> formatted
    end
  end

  def format_duration(%{observed_duration_seconds: nil}), do: "not recorded"

  def format_duration(%{observed_duration_seconds: seconds}),
    do: Ingestion.Notifier.Alert.humanize_seconds(seconds)
end
