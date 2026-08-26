defmodule Ingestion.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Ingestion.Repo,
        {DNSCluster, query: Application.get_env(:ingestion, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Ingestion.PubSub},
        {Registry, keys: :unique, name: Ingestion.SensorState.Registry},
        Ingestion.HealthMonitor.Tracker,
        Ingestion.SensorState.Supervisor
      ]
      # Turns rules-engine broadcasts into persisted incidents.
      #
      # Off in test: a globally-supervised subscriber would receive events
      # broadcast by *other* tests' sensor servers and try to write to the DB
      # without owning a sandbox connection. Tests start their own Monitor
      # (with an explicit sandbox allowance) or call handle_evaluation/5
      # directly.
      |> maybe_append(start_incident_monitor?(), Ingestion.Incidents.Monitor)
      |> maybe_append(start_escalator?(), Ingestion.Incidents.Escalator)
      |> maybe_append(live_notifier?(), Ingestion.Notifier.Live)

    opts = [strategy: :one_for_one, name: Ingestion.Supervisor]
    result = Supervisor.start_link(children, opts)

    if start_sensor_servers?(), do: start_sensor_servers()

    result
  end

  defp maybe_append(children, true, child), do: children ++ [child]
  defp maybe_append(children, false, _child), do: children

  # One GenServer per seeded Sensor record. Off in test so the suite controls
  # its own processes; on in dev and prod.
  defp start_sensor_servers do
    Task.start(fn ->
      count = Ingestion.SensorState.Bootstrap.start_all()
      require Logger
      Logger.info("started #{count} sensor state servers from the seeded inventory")
    end)
  end

  defp start_sensor_servers?, do: Application.get_env(:ingestion, :start_sensor_servers, false)
  defp start_escalator?, do: Application.get_env(:ingestion, :start_escalator, false)
  defp start_incident_monitor?, do: Application.get_env(:ingestion, :start_incident_monitor, true)

  # The Graph token cache only exists when live notifications are actually in
  # use — it is never started in dev or test.
  defp live_notifier? do
    Application.get_env(:ingestion, :notifier) == Ingestion.Notifier.Live
  end
end
