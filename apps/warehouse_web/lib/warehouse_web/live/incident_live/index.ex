defmodule WarehouseWeb.IncidentLive.Index do
  @moduledoc """
  The incident-tracking list: open incidents and closed history.

  Subscribes to `Ingestion.Incidents.topic()` so incidents raised by the
  rules engine, and lifecycle changes made in another session, appear here
  live without a refresh.

  Styled with the WFP Design System tokens already wired into the asset
  pipeline (see `docs/design-tokens.md`) — danger for critical, warning for
  elevated, success for resolved, neutral for chrome.
  """

  use WarehouseWeb, :live_view

  alias Ingestion.Incidents
  alias WarehouseWeb.IncidentComponents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Ingestion.PubSub, Incidents.topic())
    end

    {:ok,
     socket
     |> assign(page_title: "Incidents", tab: "open")
     |> reload()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, tab: Map.get(params, "tab", "open"))}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: tab)}
  end

  # Any incident lifecycle change refreshes both lists.
  @impl true
  def handle_info({event, _incident}, socket)
      when event in [
             :incident_opened,
             :incident_acknowledged,
             :incident_monitoring,
             :incident_closed,
             :incident_escalated
           ] do
    {:noreply, reload(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp reload(socket) do
    assign(socket,
      open_incidents: Incidents.list_open_incidents(),
      closed_incidents: Incidents.list_closed_incidents(limit: 50)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center justify-between mb-4">
        <div>
          <h1 class="text-2xl font-bold text-foreground">Incidents</h1>
          <p class="text-sm text-muted-foreground">
            Raised automatically by the rules engine when an FSQ-approved threshold
            is breached. Acknowledge, record what you did, then close.
          </p>
        </div>
        <.link
          navigate={~p"/rules"}
          class="rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground hover:bg-primary-700 transition-colors"
        >
          Rule Management
        </.link>
      </div>

      <div class="mb-4 flex gap-2 border-b border-border">
        <button
          type="button"
          phx-click="switch_tab"
          phx-value-tab="open"
          class={tab_class(@tab == "open")}
        >
          Open ({length(@open_incidents)})
        </button>
        <button
          type="button"
          phx-click="switch_tab"
          phx-value-tab="history"
          class={tab_class(@tab == "history")}
        >
          History ({length(@closed_incidents)})
        </button>
      </div>

      <div :if={@tab == "open"}>
        <p :if={@open_incidents == []} class="text-muted-foreground">
          No open incidents. The dashboard populates automatically when the rules
          engine detects a sustained breach of an approved threshold.
        </p>

        <ul :if={@open_incidents != []} class="space-y-3">
          <li :for={incident <- @open_incidents} id={"incident-#{incident.id}"}>
            <IncidentComponents.incident_card incident={incident} />
          </li>
        </ul>
      </div>

      <div :if={@tab == "history"}>
        <p :if={@closed_incidents == []} class="text-muted-foreground">
          No closed incidents yet.
        </p>

        <ul :if={@closed_incidents != []} class="space-y-3">
          <li :for={incident <- @closed_incidents} id={"closed-incident-#{incident.id}"}>
            <IncidentComponents.incident_card incident={incident} />
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  defp tab_class(true),
    do: "-mb-px border-b-2 border-primary px-4 py-2 text-sm font-semibold text-primary"

  defp tab_class(false),
    do:
      "-mb-px border-b-2 border-transparent px-4 py-2 text-sm font-semibold text-muted-foreground hover:text-foreground"
end
