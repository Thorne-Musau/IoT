# Smart Warehouse Food Preservation and Decision Support System

An Elixir/OTP umbrella app that ingests cold-chain sensor data from WFP
Kenya's Meraki fleet, evaluates it against FSQ-approved threshold rules,
and tracks the resulting incidents through to resolution — with automated
Outlook/Teams alerting and severity-based escalation.

## Umbrella structure

```
apps/
  ingestion/      # Ecto repo, sensor inventory, rules engine, incidents, notifications
  warehouse_web/  # Phoenix LiveView app (Rule Management + Incident Tracking)
```

### `ingestion`

- **Sensor/Zone inventory** (`Ingestion.Inventory`) — schemas and a seeded,
  idempotent load of WFP Kenya's real Meraki fleet: 16 zones, 56 sensors.
  Inventory anomalies (a duplicate device name, a coverage gap, a
  non-conforming device status, and others) are preserved as-is rather
  than normalised away — see [`docs/sensor-inventory-gaps.md`](docs/sensor-inventory-gaps.md).
- **Rules engine** (`Ingestion.RulesEngine`) — one supervised `GenServer`
  per sensor (`Ingestion.SensorState.Server`, under a `DynamicSupervisor` +
  `Registry`, keyed on the sensor's serial), each evaluating its
  commodity's approved rules with:
  - **Duration gating** — a breach only fires once sustained for the
    rule's `duration_window`.
  - **Rate-of-change trending** — a reading moving toward a boundary fast
    enough is flagged `:trending`, a distinct precursor state, before it's
    actually crossed.
  - **Hysteresis** — an alert raises exactly at the FSQ-approved
    `boundary_value`; `hysteresis_gap` only makes *clearing* stricter, so
    the system never alerts later than what FSQ approved but also doesn't
    flap at the boundary.
  - A rule can only ever be evaluated if its status is `approved` —
    enforced independently at both the query layer and the struct
    construction layer.
- **FSQ approval workflow** (`Ingestion.ThresholdRules`) — every rule
  moves `draft → pending_fsq_review → approved`, or back to `draft` on
  rejection/revision request. Editing an approved rule creates a new
  version rather than mutating it; the prior version stays live until the
  new one is itself approved. Every transition is recorded in an
  immutable audit trail (actor, timestamp, comment).
- **Health monitoring** (`Ingestion.HealthMonitor`) — distinguishes a
  single sensor going silent (missed its check-in interval) from a
  gateway appearing offline (multiple of its sensors silent together).
- **Incidents** (`Ingestion.Incidents`) — a PubSub subscriber
  (`Ingestion.Incidents.Monitor`) turns a qualifying rule breach into a
  persisted incident (`new → acknowledged → monitoring → closed`), with a
  DB constraint preventing duplicate open incidents for the same
  sensor/rule pair.
- **Notifications** (`Ingestion.Notifier`) — Outlook (Microsoft Graph
  `sendMail`) and Teams (Power Automate Workflow, Adaptive Card) behind a
  behaviour with two implementations: `Notifier.Local` (logs the
  fully-formed message; the default everywhere) and `Notifier.Live` (real
  delivery; selected only by explicit config, never in dev or test). Every
  alert's content — zone, commodity, condition, reading, duration,
  expected outcome, recommended action — is assembled entirely from the
  triggering rule and sensor/zone records, never hand-written. See
  [`docs/notification-setup.md`](docs/notification-setup.md) for exactly
  what credentials are needed to go live.
- **Escalation** (`Ingestion.Incidents.Escalator`) — an unacknowledged
  incident escalates after a severity-based window (defaults: critical 15
  minutes, lower severities longer), configurable in one place
  (`config :ingestion, :escalation` in `config/config.exs`).

### `warehouse_web`

- **Rule Management** (`/rules`) — list, create, edit, and drive rules
  through the FSQ workflow, with version history and the full audit
  trail.
- **Incident Tracking** (`/incidents`) — open incidents and closed
  history, updating live via PubSub; a detail page taking an incident from
  New through Acknowledged, Monitoring, and Closed, logging the corrective
  action taken at each step.
- Styled with WFP Design System colour, typography, and radius tokens
  ported into the Tailwind v4 pipeline — see
  [`docs/design-tokens.md`](docs/design-tokens.md).

Both apps share the umbrella's `config/` and a single `mix.lock`.

## Known gaps (deliberate, and documented)

- **No zone has a confirmed commodity yet.** The rules engine matches
  approved rules by commodity, so until warehouse ops confirms what each
  store holds, nothing is evaluated for food-safety breaches — check-in
  health monitoring still runs for every sensor regardless.
- **No real authentication.** Actor identity (who acknowledged an
  incident, who approved a rule) is free-text throughout, matching the
  scope of this phase.
- **No live Graph/Teams credentials yet.** `Notifier.Local` — log-only —
  is the default in every environment until WFP IT provisions them (see
  [`docs/notification-setup.md`](docs/notification-setup.md)).

## Running locally

Prerequisites: Elixir/OTP (see `mix.exs` for version constraints), and a
local PostgreSQL server reachable with the credentials in
`config/dev.exs` (defaults to `postgres`/`postgres` on `127.0.0.1`).

```sh
mix setup          # deps.get, ecto.create, ecto.migrate, seeds
mix phx.server      # or: iex -S mix phx.server
```

Seeding populates the real 16-zone / 56-sensor inventory plus a handful of
placeholder `draft` threshold rules (no real threshold values — FSQ hasn't
signed off on any yet).

Visit [`localhost:4000`](http://localhost:4000),
[`localhost:4000/rules`](http://localhost:4000/rules), and
[`localhost:4000/incidents`](http://localhost:4000/incidents).

To reset the local database:

```sh
mix ecto.reset
```

## Testing

```sh
mix test
```

The full suite (145 tests as of this writing) never exercises
`Notifier.Live` or any real external endpoint — enforced both by test
config and independently inside `Ingestion.Notifier.impl/0`.

## Infrastructure

`infra/terraform/` contains a Terraform skeleton (Fargate service, RDS
Postgres, a least-privilege task IAM role, and an ACM certificate) for
the AWS pilot deployment. It is scaffolding only — validate with
`terraform validate`; nothing has been planned or applied.

## Docs

- [`docs/design-tokens.md`](docs/design-tokens.md) — WFP Design System
  tokens ported into the Tailwind pipeline.
- [`docs/sensor-inventory-gaps.md`](docs/sensor-inventory-gaps.md) — the
  real Meraki fleet's known anomalies and coverage gaps.
- [`docs/notification-setup.md`](docs/notification-setup.md) — what WFP
  IT needs to provide to turn on live Outlook/Teams alerting.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
