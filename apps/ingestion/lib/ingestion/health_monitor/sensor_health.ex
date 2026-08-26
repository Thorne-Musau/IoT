defmodule Ingestion.HealthMonitor.SensorHealth do
  @moduledoc """
  Pure classification of a single sensor's check-in health.

  Distinct from `Ingestion.HealthMonitor.GatewayHealth`: this is about one
  sensor's own expected check-in cadence (it stopped reporting), not
  whether the gateway carrying it is reachable at all.
  """

  @type status :: :online | :silent

  @doc """
  `:silent` once more than `check_in_interval_ms` has elapsed since
  `last_seen_at`; `:online` otherwise.
  """
  @spec status(DateTime.t(), DateTime.t(), pos_integer()) :: status()
  def status(last_seen_at, now, check_in_interval_ms) do
    elapsed_ms = DateTime.diff(now, last_seen_at, :millisecond)

    if elapsed_ms > check_in_interval_ms, do: :silent, else: :online
  end
end
