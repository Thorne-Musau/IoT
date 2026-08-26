import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# Notifications are ALWAYS local in test. `Ingestion.Notifier.Live` must never
# be reachable from the suite: no real Graph token request, no real Teams POST,
# no dependency on network availability. `Ingestion.Notifier.dispatch/2`
# additionally refuses to use Live when Mix.env() is :test, so this is enforced
# in two independent places rather than by convention.
config :ingestion, :notifier, Ingestion.Notifier.Local

# Don't auto-start a GenServer per seeded sensor in test — the suite starts
# exactly the processes it needs.
config :ingestion, start_sensor_servers: false

# The escalator is driven manually in tests via Escalator.run_once/1 rather
# than on a timer, so results are deterministic.
config :ingestion, start_escalator: false

# Likewise the incident monitor: a globally-supervised PubSub subscriber would
# pick up rule events broadcast by other tests' sensor servers and try to write
# to the DB without owning a sandbox connection. Tests start their own.
config :ingestion, start_incident_monitor: false

config :ingestion, Ingestion.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  database: "warehouse_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :warehouse_web, WarehouseWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "vrrDPgPNEnp1PQx3sWCgYacRXQ1HTrwjN3xextvVT6UAfy20c2n+bTnvzjvUmbB1",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
