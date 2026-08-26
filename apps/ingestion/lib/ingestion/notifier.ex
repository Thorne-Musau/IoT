defmodule Ingestion.Notifier do
  @moduledoc """
  Outbound alerting for incidents, across Outlook (Microsoft Graph) and
  Teams (Power Automate Workflow webhook).

  Two implementations sit behind this behaviour:

    * `Ingestion.Notifier.Local` — logs the fully-formed message instead of
      sending it. The default in every environment, and the only one the
      test suite can reach.
    * `Ingestion.Notifier.Live` — performs real Graph and Teams calls.
      Selected *only* by explicit config (`NOTIFIER=live` in prod), never by
      default.

  `Live` being unreachable in dev/test is enforced in two independent
  places: `config/dev.exs` and `config/test.exs` pin `Local`, and
  `impl/0` below refuses to hand back `Live` when running under
  `Mix.env() in [:dev, :test]` even if config somehow says otherwise. A
  misconfiguration therefore degrades to logging, rather than emailing real
  people from a test run.
  """

  require Logger

  alias Ingestion.Incidents
  alias Ingestion.Notifier.Alert

  @typedoc "Which channel a notification went to."
  @type channel :: :outlook | :teams

  @doc "Deliver an alert over the given channel."
  @callback deliver(channel(), Alert.t()) :: :ok | {:error, term()}

  @doc """
  Notifies both channels about a newly-opened incident, then stamps
  `notified_at`. Channel failures are logged and do not raise — a Teams
  outage must not prevent the incident from being recorded or the email
  from going out.
  """
  @spec notify_new_incident(Incidents.Incident.t()) :: {:ok, Alert.t()}
  def notify_new_incident(incident) do
    alert = Alert.build(incident)
    deliver_all(alert)
    Incidents.mark_notified(incident)
    {:ok, alert}
  end

  @doc "Notifies both channels that an incident has been escalated to `contact`."
  @spec notify_escalation(Incidents.Incident.t(), String.t()) :: {:ok, Alert.t()}
  def notify_escalation(incident, contact) do
    alert = Alert.build(incident, escalation: contact)
    deliver_all(alert)
    {:ok, alert}
  end

  @doc "Sends `alert` over every channel, isolating per-channel failures."
  @spec deliver_all(Alert.t()) :: :ok
  def deliver_all(%Alert{} = alert) do
    Enum.each([:outlook, :teams], fn channel ->
      case safe_deliver(channel, alert) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "notifier: #{channel} delivery failed for incident ##{alert.incident_id}: #{inspect(reason)}"
          )
      end
    end)
  end

  defp safe_deliver(channel, alert) do
    impl().deliver(channel, alert)
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc """
  The configured implementation, with a hard floor: `Live` is never
  returned in dev or test regardless of config.
  """
  @spec impl() :: module()
  def impl do
    configured = Application.get_env(:ingestion, :notifier, Ingestion.Notifier.Local)

    if configured == Ingestion.Notifier.Live and protected_env?() do
      Logger.error(
        "notifier: Ingestion.Notifier.Live is configured but the current environment " <>
          "forbids live delivery — falling back to Ingestion.Notifier.Local."
      )

      Ingestion.Notifier.Local
    else
      configured
    end
  end

  # Mix is not available in a release, which is exactly where Live is meant
  # to run — so "no Mix" means "not a dev/test machine".
  defp protected_env? do
    function_exported?(Mix, :env, 0) and Mix.env() in [:dev, :test]
  end
end
