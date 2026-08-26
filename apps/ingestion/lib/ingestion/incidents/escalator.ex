defmodule Ingestion.Incidents.Escalator do
  @moduledoc """
  Periodically escalates incidents nobody has acknowledged.

  An incident escalates when it is still `new` — nobody has picked it up —
  and its severity's window has elapsed since `triggered_at`. Windows and
  contacts are configured in `config/config.exs` under
  `config :ingestion, :escalation` (defaults: critical 15 minutes,
  "warning"-class 60 minutes); they are operational parameters and
  deliberately do not go through FSQ approval.

  Two properties this guarantees:

    * **Acknowledging stops escalation.** `Incidents.acknowledge/2` moves
      the incident out of `new`, and the escalation query only ever looks
      at `new` incidents — so an incident acknowledged inside its window is
      never picked up, no matter when the timer next fires.
    * **Escalation happens exactly once.** `Incidents.mark_escalated/2`
      only matches an incident whose `escalated_at` is nil, and the query
      filters on that too, so a still-unacknowledged incident is not
      re-escalated on every subsequent tick.

  In test the timer is disabled (`config :ingestion, start_escalator: false`)
  and `run_once/1` is called directly, so escalation timing is asserted
  deterministically rather than by sleeping.
  """

  use GenServer

  require Logger

  alias Ingestion.{Incidents, Notifier}

  @default_check_interval_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :check_interval_ms, configured_interval())
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:check, state) do
    run_once()
    schedule(state.interval)
    {:noreply, state}
  end

  @doc """
  Escalates every incident currently past its window. Returns the list of
  escalated incidents. Safe to call repeatedly — already-escalated
  incidents are excluded by the query.
  """
  @spec run_once(DateTime.t()) :: [Incidents.Incident.t()]
  def run_once(now \\ DateTime.utc_now()) do
    now
    |> Incidents.list_escalation_due()
    |> Enum.flat_map(fn incident ->
      contact = Incidents.escalation_contact(incident.severity)

      case Incidents.mark_escalated(incident, contact) do
        {:ok, escalated} ->
          Logger.warning(
            "escalating incident ##{escalated.id} (#{escalated.severity}) to #{contact} — " <>
              "unacknowledged past its window"
          )

          Notifier.notify_escalation(escalated, contact)
          [escalated]

        {:error, :already_escalated} ->
          []
      end
    end)
  end

  defp schedule(interval), do: Process.send_after(self(), :check, interval)

  defp configured_interval do
    Application.get_env(:ingestion, :escalation, [])
    |> Keyword.get(:check_interval_ms, @default_check_interval_ms)
  end
end
