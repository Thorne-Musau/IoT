import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

config :warehouse_web, WarehouseWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :warehouse_web, WarehouseWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/warehouse_web/router\.ex$"E,
        ~r"lib/warehouse_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :ingestion, Ingestion.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :warehouse_web, WarehouseWeb.Endpoint,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## Using releases
  #
  # If you are doing OTP releases, you need to instruct Phoenix
  # to start each relevant endpoint:
  #
  #     config :warehouse_web, WarehouseWeb.Endpoint, server: true
  #
  # Then you can assemble a release by calling `mix release`.
  # See `mix help release` for more information.

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :warehouse_web, WarehouseWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :warehouse_web, WarehouseWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  config :ingestion, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # -------------------------------------------------------------------------
  # Notifications (prod only)
  #
  # Real Microsoft Graph / Teams delivery is opt-in: set NOTIFIER=live once
  # WFP IT has issued the credentials below. Until then prod also runs the
  # Local notifier, which logs the fully-formed alert instead of sending it.
  #
  # None of these values are ever hardcoded — see docs/notification-setup.md
  # for exactly what WFP IT needs to provide for each one.
  # -------------------------------------------------------------------------
  if System.get_env("NOTIFIER") == "live" do
    require_env = fn name ->
      System.get_env(name) ||
        raise """
        environment variable #{name} is missing, but NOTIFIER=live was set.

        Live notifications need all of:
          GRAPH_TENANT_ID, GRAPH_CLIENT_ID, GRAPH_CLIENT_SECRET,
          GRAPH_SENDER_MAILBOX, TEAMS_WORKFLOW_WEBHOOK_URL

        See docs/notification-setup.md. Unset NOTIFIER to fall back to the
        local (log-only) notifier.
        """
    end

    config :ingestion, :notifier, Ingestion.Notifier.Live

    config :ingestion, :graph,
      tenant_id: require_env.("GRAPH_TENANT_ID"),
      client_id: require_env.("GRAPH_CLIENT_ID"),
      client_secret: require_env.("GRAPH_CLIENT_SECRET"),
      sender_mailbox: require_env.("GRAPH_SENDER_MAILBOX"),
      recipients:
        (System.get_env("ALERT_RECIPIENTS") || "")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)

    config :ingestion, :teams, workflow_webhook_url: require_env.("TEAMS_WORKFLOW_WEBHOOK_URL")
  end

  if base = System.get_env("INCIDENT_URL_BASE") do
    config :ingestion, :incident_url_base, base
  end

  config :ingestion, start_sensor_servers: true
  config :ingestion, start_escalator: true
end
