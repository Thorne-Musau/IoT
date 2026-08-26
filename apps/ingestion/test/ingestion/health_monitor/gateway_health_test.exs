defmodule Ingestion.HealthMonitor.GatewayHealthTest do
  use ExUnit.Case, async: true

  alias Ingestion.HealthMonitor.GatewayHealth

  test "online when no sensors are known yet" do
    assert GatewayHealth.status(%{}) == :online
  end

  test "online when only some of a gateway's sensors are silent" do
    statuses = %{"sensor-1" => :silent, "sensor-2" => :online, "sensor-3" => :online}

    assert GatewayHealth.status(statuses) == :online
  end

  test "a lone silent sensor is not enough evidence the gateway is offline" do
    assert GatewayHealth.status(%{"sensor-1" => :silent}) == :online
  end

  test "offline once every known sensor on the gateway is silent together" do
    statuses = %{"sensor-1" => :silent, "sensor-2" => :silent, "sensor-3" => :silent}

    assert GatewayHealth.status(statuses) == :offline
  end

  test "min_silent_sensors raises the corroboration bar" do
    statuses = %{"sensor-1" => :silent, "sensor-2" => :silent}

    assert GatewayHealth.status(statuses, 3) == :online
  end
end
