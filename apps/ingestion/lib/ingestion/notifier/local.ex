defmodule Ingestion.Notifier.Local do
  @moduledoc """
  The dev/test notifier: logs the **fully-formed** message that `Live`
  would have sent, and sends nothing.

  It deliberately renders the same payloads as `Ingestion.Notifier.Live` —
  the plain-text mail body for Outlook, the Adaptive Card JSON for Teams —
  so what shows up in the log is exactly what would have gone out, and a
  content bug is visible in dev rather than only in production.

  For tests, `subscribe/0` gives a process-local feed of delivered alerts
  without touching global state, so a test can assert on real assembled
  content rather than on a mock.
  """

  @behaviour Ingestion.Notifier

  require Logger

  alias Ingestion.Notifier.Alert

  @topic "ingestion:notifications"

  @doc """
  Subscribes the calling process to delivered notifications. Each delivery
  arrives as `{:notification_delivered, channel, %Alert{}, rendered}`,
  where `rendered` is the exact payload the live channel would have sent.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Ingestion.PubSub, @topic)
  end

  @doc false
  def topic, do: @topic

  @impl true
  def deliver(:outlook, %Alert{} = alert) do
    rendered = Alert.to_text(alert)

    Logger.info("""
    [notifier:local] Outlook email NOT sent (local notifier). Content would have been:
    To: #{inspect(configured_recipients())}
    Subject: #{alert.subject}

    #{rendered}
    """)

    announce(:outlook, alert, rendered)
  end

  @impl true
  def deliver(:teams, %Alert{} = alert) do
    card = Alert.to_adaptive_card(alert)

    Logger.info("""
    [notifier:local] Teams Adaptive Card NOT posted (local notifier). Payload would have been:
    #{Jason.encode!(card, pretty: true)}
    """)

    announce(:teams, alert, card)
  end

  defp announce(channel, alert, rendered) do
    Phoenix.PubSub.broadcast(
      Ingestion.PubSub,
      @topic,
      {:notification_delivered, channel, alert, rendered}
    )

    :ok
  end

  defp configured_recipients do
    Application.get_env(:ingestion, :graph, [])
    |> Keyword.get(:recipients, ["<no ALERT_RECIPIENTS configured>"])
  end
end
