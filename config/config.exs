# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Configure Mix tasks and generators
config :ingestion,
  ecto_repos: [Ingestion.Repo]

# ---------------------------------------------------------------------------
# Escalation windows and contacts
#
# OPERATIONAL PARAMETERS, NOT FOOD-SAFETY THRESHOLDS. These do not go through
# the FSQ approval workflow — they govern how long an *unacknowledged*
# incident waits before being escalated to someone more senior, which is a
# staffing/response-time decision, not a food-safety one.
#
# This is the one place to change them. Windows are in seconds, keyed by the
# incident's severity (copied from the triggering rule).
# ---------------------------------------------------------------------------
config :ingestion, :escalation,
  windows: %{
    # Critical -> 15 minutes
    "critical" => 15 * 60,
    "high" => 30 * 60,
    # "Warning"-class severities -> 60 minutes
    "medium" => 60 * 60,
    "low" => 120 * 60,
    # Advisory (:trending) incidents are a developing-trend heads-up, not a
    # confirmed breach — deliberately far outside the breach-tier windows
    # above, so a trend nobody has looked at yet still eventually surfaces
    # rather than escalating on a breach-severity clock.
    "advisory" => 4 * 60 * 60
  },
  contacts: %{
    "critical" => "FSQ lead + warehouse manager",
    "high" => "FSQ lead",
    "medium" => "FSQ duty officer",
    "low" => "FSQ duty officer",
    "advisory" => "FSQ duty officer"
  },
  default_window_seconds: 60 * 60,
  default_contact: "FSQ duty officer",
  # How often the escalator wakes up to look for overdue incidents.
  check_interval_ms: 60_000

# ---------------------------------------------------------------------------
# Notifications
#
# `Ingestion.Notifier.Local` logs the fully-formed message instead of sending
# it, and is the default everywhere. `Ingestion.Notifier.Live` performs real
# Microsoft Graph / Teams calls and is ONLY ever selected by explicit config
# in prod (see config/prod.exs and config/runtime.exs). dev.exs and test.exs
# pin Local explicitly so it cannot be reached there.
# ---------------------------------------------------------------------------
config :ingestion, :notifier, Ingestion.Notifier.Local

# Base URL used to build the incident deep-link included in every alert.
config :ingestion, :incident_url_base, "http://localhost:4000/incidents"

config :warehouse_web,
  ecto_repos: [Ingestion.Repo],
  generators: [context_app: :ingestion]

# Configures the endpoint
config :warehouse_web, WarehouseWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: WarehouseWeb.ErrorHTML, json: WarehouseWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Ingestion.PubSub,
  live_view: [signing_salt: "eQ34Og1J"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  warehouse_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/warehouse_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  warehouse_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/warehouse_web", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Windows (without elevated/dev-mode symlink permission) cannot symlink the
# colocated-assets node_modules folder; this project does not use colocated
# hooks/js/css, so the warning is not actionable.
config :phoenix_live_view, :colocated_assets, disable_symlink_warning: true
