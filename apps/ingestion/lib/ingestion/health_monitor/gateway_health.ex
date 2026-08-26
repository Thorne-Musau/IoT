defmodule Ingestion.HealthMonitor.GatewayHealth do
  @moduledoc """
  Pure classification of a gateway's health from the health of the sensors
  it carries.

  Distinguishable from a single sensor going silent (`Ingestion.
  HealthMonitor.SensorHealth`): a lone silent sensor is just as likely to
  be a dead battery or a knocked-loose probe as a network problem, so it is
  not evidence the *gateway* is down. Only when every sensor known to be on
  a gateway has gone silent together — and there is more than one of them,
  so it isn't a single point of failure — do we infer the gateway itself
  is offline, since some of its sensors are still reachable in that case
  it clearly still has connectivity.
  """

  @type sensor_status :: :online | :silent
  @type status :: :online | :offline

  @doc """
  `sensor_statuses` is `%{sensor_id => :online | :silent}` for every sensor
  known to be on this gateway. `:offline` only when every one of them is
  `:silent` and there are at least `min_silent_sensors` (default `2`) of
  them; `:online` otherwise (including when the gateway has no known
  sensors yet).
  """
  @spec status(%{any() => sensor_status()}, pos_integer()) :: status()
  def status(sensor_statuses, min_silent_sensors \\ 2)

  def status(sensor_statuses, _min_silent_sensors) when map_size(sensor_statuses) == 0,
    do: :online

  def status(sensor_statuses, min_silent_sensors) do
    statuses = Map.values(sensor_statuses)

    if map_size(sensor_statuses) >= min_silent_sensors and Enum.all?(statuses, &(&1 == :silent)) do
      :offline
    else
      :online
    end
  end
end
