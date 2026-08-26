defmodule Ingestion.Alerting do
  @moduledoc """
  Extension point for outbound incident alerting: Microsoft Graph email
  and a Teams Power Automate webhook.

  Not implemented in this phase — the rules engine will call into this
  module once an incident is created.
  """
end
