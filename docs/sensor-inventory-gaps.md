# Sensor inventory: known gaps and anomalies

Notes on WFP Kenya's Meraki sensor fleet as exported. Every item below is a
**real characteristic of the deployed hardware**, not a transcription error
or a bug in this system. They are recorded here — and preserved as-is in
`Ingestion.Inventory.SeedData` — so nobody "fixes" them in the data and
quietly hides an operational gap.

Sitewide totals: **16 zones, 56 sensors** (14 food stores, 1 server room,
1 entry checkpoint).

---

## 1. Store11 has no rear-right sensor — coverage gap

Every other multi-sensor store has four corners (FL, FR, RL, RR). Store11
has only three: **RL, FR, FL**. There is no sensor covering its rear-right
corner.

**Why it matters:** conditions in Store11's RR corner are simply not
measured. A cold or damp spot there would not raise an incident, because
nothing is watching it. This is a monitoring blind spot, not a data error.

**What to do:** warehouse ops / IT should decide whether a fourth device is
warranted for Store11, or whether the three-corner layout gives acceptable
coverage for that store's size and shape.

---

## 2. Store13 has a single sensor for the whole zone

Store13 has exactly one device, `keMSAsoStore13`
(`Q3CQ-DETJ-3Z7V`), with position recorded as `single` rather than a
compass corner. Unlike every other store, it has no corner subdivision.

**Why it matters:** a single reading is treated as representative of the
entire zone. Any variation across Store13 — near a door, against an
exterior wall, close to the roof — is invisible. It also means the zone has
no redundancy: if that one sensor goes silent, Store13 becomes entirely
unmonitored at once.

**What to do:** confirm whether Store13 is small enough that one sensor is
genuinely adequate, or whether it is under-instrumented relative to the
other stores.

---

## 3. Store14 uses numeric positions instead of compass corners

Store14's four sensors are named `keMSAsoStore14-01` through `-04`, with
positions `01`, `02`, `03`, `04`. Every other multi-sensor store uses
`FL` / `FR` / `RL` / `RR`.

**Why it matters:** the numeric suffixes carry no spatial meaning. When an
incident fires on `keMSAsoStore14-03`, nobody reading the alert can tell
*where in Store14* to go without a separate reference. The compass naming
elsewhere is self-describing; this is not.

**What to do:** map `01`–`04` to physical corners and rename in Meraki, or
publish the mapping somewhere responders can reach it.

---

## 4. Two different devices share the name `keMSAsoStore3-FL`

Store3 has **two distinct physical sensors with the same display name**:

| Name | Serial |
|---|---|
| `keMSAsoStore3-FL` | `Q3CQ-96DA-V53R` |
| `keMSAsoStore3-FL` | `Q3CQ-EBP3-FCM5` |

This is real. It has not been renamed or de-duplicated in this system.

**Why it matters:** display name alone is ambiguous for Store3 — an alert
saying "keMSAsoStore3-FL" does not identify which of the two devices
raised it. This is exactly why the `sensors` table is keyed on **`serial`**
(unique, not null) and treats `name` as display-only and non-unique.
Anywhere the identity of a Store3-FL device actually matters, use the
serial.

**What to do:** rename one of them in Meraki so the display names are
distinct. Until then, the serial is the only reliable identifier, and
alerts for Store3 should be read with that in mind.

---

## 5. One water/leak sensor for the entire site

`keMSAsoSE1` (`Q3CB-9N4K-D33G`, model **MT12**) at the SE entry checkpoint
is the **only water/leak sensor anywhere on site**. Every other device is
an IAQ sensor (MT15, plus one MT14).

**Why it matters:** leak detection covers the entry checkpoint only. A leak
inside any of the fourteen food stores would not be detected directly —
at best it might show up indirectly as a humidity change on an IAQ sensor,
which is a much weaker and slower signal.

Additionally, this device was reported **"alerting" with 65% battery** at
export time. Its current state should be verified before it is assumed
healthy — it is seeded with `battery_pct: 65` and a note, not as a clean
device.

**What to do:** decide whether leak coverage is needed inside the food
stores, and confirm the current status of the existing MT12.

---

## 6. Store10-RL reported "Non-conforming" by Meraki

`keMSAsoStore10-RL` (`Q3CQ-9M7Z-WPDT`) carries a Meraki device status of
**Non-conforming**, most likely a firmware or configuration mismatch.

**Why it matters — and what it is not:** this is a **device-health**
problem, not a food-safety event. The readings from a non-conforming device
may be unreliable, but the condition itself says nothing about the
temperature or humidity of the food in Store10. This system deliberately
never converts `meraki_status` into a food-safety incident; it is surfaced
as an equipment flag only (`Ingestion.Inventory.list_flagged_sensors/0`).

**What to do:** IT should reconcile the device's firmware/config. Until
then, readings from this sensor should be treated with reduced confidence.

---

## Related: battery levels

`battery_pct` is nullable and means **"not known"**. It is populated only
where the Meraki export actually reported a level:

| Sensor | Serial | Battery |
|---|---|---|
| `keMSAsoSE1` | `Q3CB-9N4K-D33G` | 65% |
| `keMSAsoSE01` | `Q3CG-VAYR-FHQE` | 29% — low, verify |

Every other sensor is seeded `nil`, **not `0`** — an unknown battery level
and a flat battery are very different things, and conflating them would
manufacture a fleet-wide false alarm. `rssi_dbm` was not in the export at
all and is `nil` throughout.

`keMSAsoSE01`'s 29% is genuinely low and should be checked.

---

## Related: commodity is not yet set on any zone

Every zone's `commodity` field is deliberately `nil`. Which commodity each
store actually holds has not been confirmed by warehouse ops.

This has a direct functional consequence: the rules engine matches approved
threshold rules **by commodity**, so a zone with no commodity has no rules
to evaluate and is not assessed for food-safety breaches. Check-in health
monitoring still runs for those sensors — a silent device is still
reported — but environmental thresholds are not applied.

Filling these in (`zones.commodity`) is a prerequisite for the rules engine
doing anything useful in production, and is tracked as
`# TODO: confirm with warehouse ops` in `Ingestion.Inventory.SeedData`.
