defmodule Ingestion.Incidents do
  @moduledoc """
  Persistence and lifecycle for food-safety incidents.

  The rules engine itself stays pure and stateless about incidents — it
  only broadcasts evaluation transitions. `Ingestion.Incidents.Monitor`
  subscribes to those broadcasts and calls into this module, which is the
  only place incidents are created or moved between statuses.

  Actor identity is free-text throughout (`acknowledged_by`), matching
  Phase 2. Real authentication is a known, deliberate gap.
  """

  import Ecto.Query, warn: false

  alias Ingestion.Incidents.Incident
  alias Ingestion.Repo

  @topic "ingestion:incidents"

  @doc "PubSub topic on which incident lifecycle changes are announced."
  def topic, do: @topic

  ## Reads

  @doc "Open incidents (anything not `closed`), most recently triggered first."
  @spec list_open_incidents() :: [Incident.t()]
  def list_open_incidents do
    from(i in Incident,
      where: i.status in ^Incident.open_statuses(),
      order_by: [desc: i.triggered_at, desc: i.id],
      preload: [:rule, sensor: :zone]
    )
    |> Repo.all()
  end

  @doc "Closed incidents, most recently resolved first — the incident history."
  @spec list_closed_incidents(keyword()) :: [Incident.t()]
  def list_closed_incidents(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    from(i in Incident,
      where: i.status == "closed",
      order_by: [desc: i.resolved_at, desc: i.id],
      limit: ^limit,
      preload: [:rule, sensor: :zone]
    )
    |> Repo.all()
  end

  @doc "Fetches one incident with rule, sensor and zone preloaded. Raises if missing."
  @spec get_incident!(integer()) :: Incident.t()
  def get_incident!(id) do
    from(i in Incident, where: i.id == ^id, preload: [:rule, sensor: :zone])
    |> Repo.one!()
  end

  @doc "The currently-open incident for a sensor/rule pair, or nil."
  @spec get_open_incident(integer(), integer()) :: Incident.t() | nil
  def get_open_incident(sensor_id, rule_id) do
    from(i in Incident,
      where:
        i.sensor_id == ^sensor_id and i.rule_id == ^rule_id and
          i.status in ^Incident.open_statuses(),
      preload: [:rule, sensor: :zone]
    )
    |> Repo.one()
  end

  ## Creation

  @doc """
  Creates an incident. Returns `{:error, :already_open}` rather than a
  changeset error when one is already open for the same sensor/rule pair,
  so a sustained breach that keeps re-broadcasting is idempotent.
  """
  @spec create_incident(map()) ::
          {:ok, Incident.t()} | {:error, :already_open | Ecto.Changeset.t()}
  def create_incident(attrs) do
    %Incident{}
    |> Incident.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, incident} ->
        incident = get_incident!(incident.id)
        broadcast({:incident_opened, incident})
        {:ok, incident}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Enum.any?(errors, fn {_field, {msg, _}} -> msg == "already has an open incident" end) do
          {:error, :already_open}
        else
          {:error, changeset}
        end
    end
  end

  ## Lifecycle transitions

  @doc "Moves a `new` incident to `acknowledged`, recording who took it."
  @spec acknowledge(Incident.t(), String.t()) ::
          {:ok, Incident.t()} | {:error, :invalid_transition | :missing_actor}
  def acknowledge(%Incident{status: "new"} = incident, actor) do
    if blank?(actor) do
      {:error, :missing_actor}
    else
      incident
      |> Ecto.Changeset.change(
        status: "acknowledged",
        acknowledged_at: now(),
        acknowledged_by: String.trim(actor)
      )
      |> update_and_broadcast(:incident_acknowledged)
    end
  end

  def acknowledge(%Incident{}, _actor), do: {:error, :invalid_transition}

  @doc """
  Records the corrective action taken and moves an `acknowledged` incident
  to `monitoring`. The action text is required — an incident cannot move on
  without a record of what was actually done about it.
  """
  @spec record_corrective_action(Incident.t(), String.t()) ::
          {:ok, Incident.t()} | {:error, :invalid_transition | :missing_action}
  def record_corrective_action(%Incident{status: "acknowledged"} = incident, action) do
    if blank?(action) do
      {:error, :missing_action}
    else
      incident
      |> Ecto.Changeset.change(status: "monitoring", corrective_action: String.trim(action))
      |> update_and_broadcast(:incident_monitoring)
    end
  end

  def record_corrective_action(%Incident{}, _action), do: {:error, :invalid_transition}

  @doc "Closes a `monitoring` incident, stamping `resolved_at`."
  @spec close(Incident.t()) :: {:ok, Incident.t()} | {:error, :invalid_transition}
  def close(%Incident{status: "monitoring"} = incident) do
    incident
    |> Ecto.Changeset.change(status: "closed", resolved_at: now())
    |> update_and_broadcast(:incident_closed)
  end

  def close(%Incident{}), do: {:error, :invalid_transition}

  @doc "Marks an incident as escalated to `contact`. Idempotent — a second call is a no-op."
  @spec mark_escalated(Incident.t(), String.t()) ::
          {:ok, Incident.t()} | {:error, :already_escalated}
  def mark_escalated(%Incident{escalated_at: nil} = incident, contact) do
    incident
    |> Ecto.Changeset.change(escalated_at: now(), escalated_to: contact)
    |> update_and_broadcast(:incident_escalated)
  end

  def mark_escalated(%Incident{}, _contact), do: {:error, :already_escalated}

  @doc "Stamps `notified_at` once the opening alert has been dispatched."
  @spec mark_notified(Incident.t()) :: {:ok, Incident.t()}
  def mark_notified(%Incident{} = incident) do
    incident
    |> Ecto.Changeset.change(notified_at: now())
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, %{updated | rule: incident.rule, sensor: incident.sensor}}
      other -> other
    end
  end

  ## Escalation queries

  @doc """
  Incidents still in `new` (nobody has acknowledged them), never escalated,
  whose severity-specific window has elapsed since `triggered_at`.

  Acknowledging an incident takes it out of `new` and therefore out of this
  query — which is exactly why acknowledging within the window prevents
  escalation.
  """
  @spec list_escalation_due(DateTime.t()) :: [Incident.t()]
  def list_escalation_due(now \\ DateTime.utc_now()) do
    from(i in Incident,
      where: i.status == "new" and is_nil(i.escalated_at),
      preload: [:rule, sensor: :zone]
    )
    |> Repo.all()
    |> Enum.filter(&escalation_due?(&1, now))
  end

  @doc "Whether `incident` has passed its severity's escalation window as of `now`."
  @spec escalation_due?(Incident.t(), DateTime.t()) :: boolean()
  def escalation_due?(%Incident{status: "new", escalated_at: nil} = incident, now) do
    DateTime.diff(now, incident.triggered_at, :second) >=
      escalation_window_seconds(incident.severity)
  end

  def escalation_due?(%Incident{}, _now), do: false

  @doc """
  The escalation window for a severity, in seconds.

  Configured in `config/config.exs` under
  `config :ingestion, :escalation, windows: %{...}` — an operational
  parameter, deliberately *not* part of the FSQ-approved rule content, but
  kept in one findable place rather than scattered as literals.
  """
  @spec escalation_window_seconds(String.t()) :: pos_integer()
  def escalation_window_seconds(severity) do
    config = Application.get_env(:ingestion, :escalation, [])
    windows = Keyword.get(config, :windows, %{})
    default = Keyword.get(config, :default_window_seconds, 3600)

    Map.get(windows, severity, default)
  end

  @doc "Who an incident of this severity escalates to. Configured alongside the windows."
  @spec escalation_contact(String.t()) :: String.t()
  def escalation_contact(severity) do
    config = Application.get_env(:ingestion, :escalation, [])
    contacts = Keyword.get(config, :contacts, %{})
    default = Keyword.get(config, :default_contact, "FSQ duty officer")

    Map.get(contacts, severity, default)
  end

  ## Helpers

  defp update_and_broadcast(changeset, event) do
    case Repo.update(changeset) do
      {:ok, updated} ->
        incident = get_incident!(updated.id)
        broadcast({event, incident})
        {:ok, incident}

      other ->
        other
    end
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Ingestion.PubSub, @topic, message)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
end
