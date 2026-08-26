defmodule Ingestion.MqttEndpoint do
  @moduledoc """
  Extension point for the MQTT broker endpoint that Meraki gateways will
  publish sensor readings to directly (TLS on port 443, username/password
  auth). This app is intended to act as the MQTT broker itself rather
  than routing ingestion through AWS IoT Core.

  Not implemented in this phase — this module marks where the listener
  and its supervision will be wired in.
  """
end
