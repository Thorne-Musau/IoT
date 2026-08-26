# Notification setup: what WFP IT needs to provide

Incident alerts go out over two channels: **Outlook** (email via Microsoft
Graph) and **Teams** (an Adaptive Card posted to a Power Automate Workflow).

Neither channel has real WFP-issued credentials yet. Until they do, the
system runs `Ingestion.Notifier.Local`, which **logs the fully-formed
message it would have sent and sends nothing**. No configuration is needed
to run in that mode — it is the default in every environment.

Nothing in this repository contains a real mailbox address, tenant ID,
client secret, or webhook URL. Every value below is read from an
environment variable at runtime.

---

## Turning live notifications on

Live delivery is opt-in and production-only. It requires **both**:

1. `NOTIFIER=live` in the environment, and
2. every variable in the two tables below.

If `NOTIFIER=live` is set but any variable is missing, the app refuses to
boot with a message naming the missing one — a half-configured notifier
fails loudly rather than silently dropping alerts.

Live delivery is impossible in dev and test by construction:
`config/dev.exs` and `config/test.exs` pin the local notifier, and
`Ingestion.Notifier.impl/0` independently refuses to return the live
implementation when running under `Mix.env() in [:dev, :test]`. A
misconfiguration degrades to logging rather than emailing real people from
a test run.

---

## 1. Outlook — Microsoft Graph `sendMail`

### What IT needs to create

An **app registration** in Entra ID (Azure AD) with:

| Requirement | Value |
|---|---|
| Permission | **`Mail.Send`** — **Application**, not Delegated |
| Admin consent | **Required.** Application permissions do not work without tenant admin consent |
| Credential | A client secret (or certificate) |
| Sender | A **shared mailbox** the app is allowed to send as |

The app uses the **OAuth 2.0 client credentials** flow — there is no signed-in
user, which is why the permission must be Application rather than Delegated.

> **Security note worth raising with IT:** `Mail.Send` as an application
> permission grants the ability to send mail as *any* mailbox in the tenant
> by default. If your security posture requires it, ask IT to scope this down
> with an **application access policy**
> (`New-ApplicationAccessPolicy`) restricting the app to the single shared
> mailbox below. This is a standard hardening step and is recommended.

### Environment variables

| Variable | What it is | Example shape |
|---|---|---|
| `GRAPH_TENANT_ID` | Directory (tenant) ID of the WFP Entra tenant | a GUID |
| `GRAPH_CLIENT_ID` | Application (client) ID of the app registration | a GUID |
| `GRAPH_CLIENT_SECRET` | Client secret value | an opaque string — **treat as a password** |
| `GRAPH_SENDER_MAILBOX` | Shared mailbox alerts are sent *from* | an address in the WFP tenant |
| `ALERT_RECIPIENTS` | Who receives alerts, comma-separated | `a@example.org,b@example.org` |

`GRAPH_CLIENT_SECRET` must be delivered through a secret store or credential
manager, never committed, and never pasted into a ticket. Note its **expiry
date** — Entra client secrets expire (commonly 6, 12 or 24 months) and
alerting will stop silently at the wall when it lapses. Put a calendar
reminder against it.

### What the app does with them

1. `POST https://login.microsoftonline.com/{GRAPH_TENANT_ID}/oauth2/v2.0/token`
   with `grant_type=client_credentials` and scope
   `https://graph.microsoft.com/.default`.
2. `POST https://graph.microsoft.com/v1.0/users/{GRAPH_SENDER_MAILBOX}/sendMail`
   with the alert as an HTML message.

Tokens are cached in-process until shortly before expiry, so a burst of
incidents does not trigger a burst of token requests.

---

## 2. Teams — Power Automate Workflow webhook

### What IT needs to create

A **Power Automate Workflow** ("Post to a channel when a webhook request is
received") targeting the channel that should receive alerts. Its trigger
gives an HTTPS URL — that URL is the credential.

> **This must be a Power Automate *Workflow* webhook.** The older Office 365
> **Incoming Webhook connector** — and its `MessageCard` payload format — has
> been retired by Microsoft and will not work. This system sends an
> **Adaptive Card** wrapped in the `{"type": "message", "attachments": [...]}`
> envelope that Workflows expects. If someone supplies a legacy connector
> URL, alerts will fail.

### Environment variable

| Variable | What it is |
|---|---|
| `TEAMS_WORKFLOW_WEBHOOK_URL` | The full HTTPS trigger URL from the Workflow |

The URL contains an embedded signature and **is itself a secret** — anyone
holding it can post into that Teams channel. Store it like a password and
rotate it (by regenerating the trigger) if it leaks.

---

## 3. Incident deep links

Every alert includes a link back to the incident in the tracking UI.

| Variable | What it is | Default |
|---|---|---|
| `INCIDENT_URL_BASE` | Public base URL of the incident list | `http://localhost:4000/incidents` |

Set this to the real deployed hostname, otherwise every alert will link to
`localhost` and be useless to whoever receives it.

---

## Summary for a ticket to IT

> We need to send automated food-safety alerts from an Elixir service to
> Outlook and Teams. Please provide:
>
> 1. An Entra ID app registration with the **`Mail.Send` application
>    permission**, admin-consented, plus its **tenant ID**, **client ID**, and
>    a **client secret** (with its expiry date).
> 2. A **shared mailbox** the app may send from — and, if required by policy,
>    an **application access policy** scoping the app to only that mailbox.
> 3. The **distribution list or addresses** that should receive alerts.
> 4. A **Power Automate Workflow webhook URL** for the target Teams channel.
>    (Not a legacy Incoming Webhook connector — that format is retired.)
> 5. The **public hostname** the incident tracking UI will be served on.
>
> Items 1, 2 and 4 include secrets; please deliver them via the credential
> store rather than in the ticket body.

---

## Verifying without sending anything

Because the local notifier renders the *exact* payloads the live one would
send, the content can be reviewed end to end before any credentials exist:

```
mix phx.server        # dev — always uses the local notifier
```

Trigger an incident and the full email body and Adaptive Card JSON are
written to the log, tagged `[notifier:local]`. What appears there is
byte-for-byte what will go out once live delivery is switched on.

---

## Alert content

Alert copy is **not hand-written anywhere**. Each alert is assembled from
the triggering rule's own FSQ-approved fields and the sensor/zone records:

| Element | Source |
|---|---|
| Zone | `zones.name` |
| Commodity | `zones.commodity` — renders as "not confirmed" when unset; never invented |
| Sensor | `sensors.name` **and `sensors.serial`** (names are not unique — see `sensor-inventory-gaps.md`) |
| Condition | `threshold_rules.trigger_condition` |
| Current reading | Snapshot taken when the engine raised |
| Persisted for | Snapshot taken when the engine raised |
| Expected outcome | `threshold_rules.expected_outcome` |
| Recommended action | `threshold_rules.recommended_action` |
| Source reference | `threshold_rules.source_reference` |
| Link | `INCIDENT_URL_BASE` + incident id |

When FSQ revises an approved rule's wording, the alerts change with it — no
code change and no redeploy.
