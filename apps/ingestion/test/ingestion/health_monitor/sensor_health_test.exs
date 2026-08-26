defmodule Ingestion.HealthMonitor.SensorHealthTest do
  use ExUnit.Case, async: true

  alias Ingestion.HealthMonitor.SensorHealth

  test "online when last seen within the check-in interval" do
    now = ~U[2026-01-01 12:00:00Z]
    last_seen_at = DateTime.add(now, -30, :second)

    assert SensorHealth.status(last_seen_at, now, 60_000) == :online
  end

  test "online exactly at the check-in interval boundary" do
    now = ~U[2026-01-01 12:00:00Z]
    last_seen_at = DateTime.add(now, -60, :second)

    assert SensorHealth.status(last_seen_at, now, 60_000) == :online
  end

  test "silent once more than the check-in interval has elapsed" do
    now = ~U[2026-01-01 12:00:00Z]
    last_seen_at = DateTime.add(now, -61, :second)

    assert SensorHealth.status(last_seen_at, now, 60_000) == :silent
  end
end
