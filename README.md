# Smart Warehouse Food Preservation and Decision Support System

Phase 1 scaffolding for an Elixir/OTP umbrella app that ingests warehouse
sensor data, evaluates it against threshold rules, and surfaces incidents
on a live dashboard.

## Umbrella structure

```
apps/
  ingestion/      # Ecto repo, migrations, and the rules-engine skeleton
  warehouse_web/  # Phoenix LiveView app (incident dashboard)
```

- **`ingestion`** owns the `Ingestion.Repo` Ecto repo and schema-less
  migrations for `zones`, `sensors`, `threshold_rules`, and `incidents`.
  It also holds the structural skeleton for the future rules engine:
  - `Ingestion.SensorState.Server` / `Supervisor` — one `GenServer` per
    sensor, registered via `Ingestion.SensorState.Registry`, holding a
    rolling window of recent readings. Duration-gated thresholds,
    rate-of-change trending, and hysteresis will read from this window;
    detection logic itself is not implemented yet.
  - `Ingestion.MqttEndpoint` — extension point for the MQTT broker
    endpoint that Meraki gateways will publish to directly (TLS on port
    443, username/password auth). The app is intended to act as the
    broker itself, not route through AWS IoT Core. Not wired up yet.
  - `Ingestion.Alerting` — extension point for outbound incident
    alerting (Microsoft Graph email, Teams Power Automate webhook). Not
    implemented yet.
- **`warehouse_web`** is a Phoenix LiveView app serving a placeholder
  incident-list page (`/incidents`) from the same umbrella, communicating
  with `ingestion` over `Ingestion.PubSub`.

Both apps share the umbrella's `config/` and a single `mix.lock`.

## Running locally

Prerequisites: Elixir/OTP (see `mix.exs` for version constraints), and a
local PostgreSQL server reachable with the credentials in
`config/dev.exs` (defaults to `postgres`/`postgres` on `localhost`).

```sh
mix setup          # deps.get, ecto.create, ecto.migrate, seeds
mix phx.server      # or: iex -S mix phx.server
```

Visit [`localhost:4000`](http://localhost:4000) and
[`localhost:4000/incidents`](http://localhost:4000/incidents).

To reset the local database:

```sh
mix ecto.reset
```

## Infrastructure

`infra/terraform/` contains a Terraform skeleton (Fargate service, RDS
Postgres, a least-privilege task IAM role, and an ACM certificate) for
the AWS pilot deployment. It is scaffolding only — validate with
`terraform validate`; nothing has been planned or applied.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
