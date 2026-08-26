defmodule WarehouseWeb.IncidentLive.Show do
  @moduledoc """
  Incident detail: the full context the responder needs, and the actions
  that move it through the lifecycle.

  The action shown is always the single next step for the incident's
  current status — acknowledge when `new`, log corrective action when
  `acknowledged`, close when `monitoring` — so the four-state model is
  enforced by what the UI offers as well as by the context functions
  behind it.

  Actor identity is free-text, matching Phase 2. Real authentication is a
  known, deliberate gap for this phase.
  """

  use WarehouseWeb, :live_view

  alias Ingestion.Incidents
  alias WarehouseWeb.IncidentComponents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Ingestion.PubSub, Incidents.topic())
    end

    incident = Incidents.get_incident!(id)

    {:ok, assign(socket, incident: incident, page_title: "Incident ##{incident.id}")}
  end

  @impl true
  def handle_event("acknowledge", %{"actor" => actor}, socket) do
    socket.assigns.incident
    |> Incidents.acknowledge(actor)
    |> respond(socket, "Incident acknowledged.")
  end

  def handle_event("record_action", %{"corrective_action" => action}, socket) do
    socket.assigns.incident
    |> Incidents.record_corrective_action(action)
    |> respond(socket, "Corrective action recorded. Incident is now being monitored.")
  end

  def handle_event("close", _params, socket) do
    socket.assigns.incident
    |> Incidents.close()
    |> respond(socket, "Incident closed.")
  end

  # Keep the page live if this incident changes elsewhere.
  @impl true
  def handle_info({_event, %{id: id} = incident}, socket) do
    if id == socket.assigns.incident.id do
      {:noreply, assign(socket, incident: incident)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp respond({:ok, incident}, socket, message) do
    {:noreply,
     socket
     |> assign(incident: incident)
     |> put_flash(:info, message)}
  end

  defp respond({:error, :missing_actor}, socket, _message) do
    {:noreply, put_flash(socket, :error, "Enter your name before acknowledging.")}
  end

  defp respond({:error, :missing_action}, socket, _message) do
    {:noreply,
     put_flash(socket, :error, "Describe the corrective action taken before continuing.")}
  end

  defp respond({:error, :invalid_transition}, socket, _message) do
    {:noreply,
     socket
     |> assign(incident: Incidents.get_incident!(socket.assigns.incident.id))
     |> put_flash(:error, "That action no longer applies to this incident's status.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mb-4">
        <.link navigate={~p"/incidents"} class="text-sm text-primary hover:text-primary-700">
          &larr; Back to incidents
        </.link>
      </div>

      <div class="rounded-lg border border-border bg-card p-6">
        <div class="flex flex-wrap items-center gap-2">
          <IncidentComponents.severity_badge severity={@incident.severity} />
          <IncidentComponents.status_badge status={@incident.status} />
          <IncidentComponents.escalated_badge
            :if={@incident.escalated_at}
            to={@incident.escalated_to}
          />
        </div>

        <h1 class="mt-3 text-2xl font-bold text-foreground">
          {IncidentComponents.zone_name(@incident)}
          <span class="text-base font-normal text-muted-foreground">
            · Incident #{@incident.id}
          </span>
        </h1>

        <dl class="mt-4 grid grid-cols-1 gap-x-6 gap-y-3 sm:grid-cols-2">
          <.detail label="Zone">{IncidentComponents.zone_name(@incident)}</.detail>
          <.detail label="Commodity">{IncidentComponents.commodity(@incident)}</.detail>
          <.detail label="Sensor">{IncidentComponents.sensor_label(@incident)}</.detail>
          <.detail label="Current reading">{IncidentComponents.format_reading(@incident)}</.detail>
          <.detail label="Persisted for">{IncidentComponents.format_duration(@incident)}</.detail>
          <.detail label="Triggered at">
            {IncidentComponents.format_datetime(@incident.triggered_at)}
          </.detail>
        </dl>

        <div class="mt-5 border-t border-border pt-4">
          <h2 class="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            Condition
          </h2>
          <p class="mt-1 text-sm text-card-foreground">
            {IncidentComponents.condition(@incident)}
          </p>
        </div>

        <div :if={@incident.rule && @incident.rule.expected_outcome} class="mt-4">
          <h2 class="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            Expected outcome if unaddressed
          </h2>
          <p class="mt-1 text-sm text-card-foreground">{@incident.rule.expected_outcome}</p>
        </div>

        <div :if={@incident.rule && @incident.rule.recommended_action} class="mt-4">
          <h2 class="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            Recommended action
          </h2>
          <p class="mt-1 rounded-md bg-primary-50 px-3 py-2 text-sm text-card-foreground">
            {@incident.rule.recommended_action}
          </p>
        </div>
      </div>

      <!-- Lifecycle actions: only the next valid step is ever offered. -->
      <div class="mt-4 rounded-lg border border-border bg-card p-6">
        <h2 class="text-sm font-semibold text-card-foreground">Response</h2>

        <form
          :if={@incident.status == "new"}
          phx-submit="acknowledge"
          class="mt-3 flex flex-wrap items-end gap-2"
        >
          <div>
            <label class="block text-xs font-semibold text-muted-foreground mb-1">Your name</label>
            <input
              type="text"
              name="actor"
              required
              placeholder="e.g. j.operator"
              class="w-56 rounded-md border border-input px-2 py-1.5 text-sm"
            />
          </div>
          <button
            type="submit"
            class="rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground hover:bg-primary-700"
          >
            Acknowledge
          </button>
        </form>

        <form
          :if={@incident.status == "acknowledged"}
          phx-submit="record_action"
          class="mt-3 space-y-2"
        >
          <div>
            <label class="block text-xs font-semibold text-muted-foreground mb-1">
              Corrective action taken
            </label>
            <textarea
              name="corrective_action"
              required
              rows="3"
              placeholder="What did you actually do?"
              class="w-full rounded-md border border-input px-2 py-1.5 text-sm"
            ></textarea>
          </div>
          <button
            type="submit"
            class="rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground hover:bg-primary-700"
          >
            Record action &amp; monitor
          </button>
        </form>

        <div :if={@incident.status == "monitoring"} class="mt-3">
          <p class="text-sm text-muted-foreground">
            Corrective action recorded. Close the incident once the condition is
            confirmed to have held.
          </p>
          <button
            type="button"
            phx-click="close"
            class="mt-2 rounded-lg bg-success-600 px-4 py-2 text-sm font-semibold text-white hover:bg-success-700"
          >
            Close incident
          </button>
        </div>

        <p :if={@incident.status == "closed"} class="mt-3 text-sm text-success-700">
          This incident was closed on {IncidentComponents.format_datetime(@incident.resolved_at)}.
        </p>
      </div>

      <!-- Audit-style trail of what happened and who did it. -->
      <div class="mt-4 rounded-lg border border-border bg-card p-6">
        <h2 class="text-sm font-semibold text-card-foreground">Incident log</h2>
        <ul class="mt-3 space-y-2 text-xs">
          <li class="text-card-foreground">
            <span class="font-semibold">Raised</span>
            by the rules engine on {IncidentComponents.format_datetime(@incident.triggered_at)}
          </li>
          <li :if={@incident.notified_at} class="text-card-foreground">
            <span class="font-semibold">Notified</span>
            via Outlook and Teams on {IncidentComponents.format_datetime(@incident.notified_at)}
          </li>
          <li :if={@incident.escalated_at} class="text-danger-700">
            <span class="font-semibold">Escalated</span>
            to {@incident.escalated_to} on {IncidentComponents.format_datetime(@incident.escalated_at)}
          </li>
          <li :if={@incident.acknowledged_at} class="text-card-foreground">
            <span class="font-semibold">Acknowledged</span>
            by {@incident.acknowledged_by} on {IncidentComponents.format_datetime(
              @incident.acknowledged_at
            )}
          </li>
          <li :if={@incident.corrective_action} class="text-card-foreground">
            <span class="font-semibold">Corrective action:</span>
            {@incident.corrective_action}
          </li>
          <li :if={@incident.resolved_at} class="text-success-700">
            <span class="font-semibold">Closed</span>
            on {IncidentComponents.format_datetime(@incident.resolved_at)}
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp detail(assigns) do
    ~H"""
    <div>
      <dt class="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
        {@label}
      </dt>
      <dd class="mt-0.5 text-sm text-card-foreground">{render_slot(@inner_block)}</dd>
    </div>
    """
  end
end
