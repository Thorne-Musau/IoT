defmodule Ingestion.Inventory.SeedData do
  @moduledoc """
  WFP Kenya's real Meraki sensor inventory, as exported.

  Kept as a module (rather than inline in `seeds.exs`) so the seeding logic
  and the tests that assert seed integrity read from exactly the same
  source of truth.

  The inventory's real-world anomalies are represented here rather than
  normalised away — see `docs/sensor-inventory-gaps.md`:

    * `Store3-FL` appears twice, two different serials, same display name.
    * `Store11` has no RR sensor (a genuine coverage gap).
    * `Store13` has a single sensor for the whole zone, no corner split.
    * `Store14` uses numeric positions (`01`..`04`) instead of compass corners.
    * `Store10-RL` is reported `non_conforming` by Meraki.
    * `SE` holds the only water/leak sensor sitewide.

  Every zone's `commodity` is `nil` on purpose: unconfirmed by warehouse ops.
  """

  @storage_zones ~w(
    Store1 Store2 Store3 Store4 Store5 Store6 Store7
    Store8 Store9 Store10 Store11 Store12 Store13 Store14
  )

  @doc """
  Zone definitions: `{name, zone_type, description}`.

  # TODO: confirm with warehouse ops which commodity each storage zone
  # holds. Left nil deliberately — an invented commodity would silently put
  # the wrong FSQ-approved thresholds in front of real stock.
  """
  @spec zones() :: [%{name: String.t(), zone_type: String.t(), description: String.t()}]
  def zones do
    storage =
      Enum.map(@storage_zones, fn name ->
        %{name: name, zone_type: "storage", description: "Food storage zone #{name}"}
      end)

    storage ++
      [
        %{
          name: "SRV",
          zone_type: "server_room",
          description: "Server room. Not food storage — excluded from FSQ threshold scope."
        },
        %{
          name: "SE",
          zone_type: "entry_point",
          description:
            "Site entry checkpoint. Not food storage — excluded from FSQ threshold scope."
        }
      ]
  end

  @doc """
  Sensor definitions, keyed on the real Meraki `serial`.

  `battery_pct` is populated only where the export actually reported it
  (SE1: 65, SE01: 29) and is `nil` — meaning "unknown" — everywhere else,
  never `0`. `rssi_dbm` was not in the export at all and is `nil`
  throughout.
  """
  @spec sensors() :: [map()]
  def sensors do
    [
      s("Store1", "FR", "keMSAsoStore1-FR", "Q3CQ-4Y5F-59LL"),
      s("Store1", "RR", "keMSAsoStore1-RR", "Q3CQ-ACWV-N6WZ"),
      s("Store1", "RL", "keMSAsoStore1-RL", "Q3CQ-BV6F-TNUB"),
      s("Store1", "FL", "keMSAsoStore1-FL", "Q3CQ-C4RX-SS2Q"),
      s("Store2", "RL", "keMSAsoStore2-RL", "Q3CQ-DRZW-BMN3"),
      s("Store2", "FR", "keMSAsoStore2-FR", "Q3CQ-FKDT-QDDM"),
      s("Store2", "RR", "keMSAsoStore2-RR", "Q3CQ-P7BL-X5QC"),
      s("Store2", "FL", "keMSAsoStore2-FL", "Q3CQ-Y7JG-WBUM"),
      s("Store3", "RL", "keMSAsoStore3-RL", "Q3CQ-4HGC-XMHJ"),
      s("Store3", "FL", "keMSAsoStore3-FL", "Q3CQ-96DA-V53R",
        notes:
          "Duplicate display name with Q3CQ-EBP3-FCM5 — two distinct devices share " <>
            "the name keMSAsoStore3-FL in the Meraki export. Preserved as-is; serial is the key."
      ),
      s("Store3", "FL", "keMSAsoStore3-FL", "Q3CQ-EBP3-FCM5",
        notes:
          "Duplicate display name with Q3CQ-96DA-V53R — two distinct devices share " <>
            "the name keMSAsoStore3-FL in the Meraki export. Preserved as-is; serial is the key."
      ),
      s("Store3", "RR", "keMSAsoStore3-RR", "Q3CQ-RWYP-V4YY"),
      s("Store4", "RL", "keMSAsoStore4-RL", "Q3CQ-7C7A-PBBR"),
      s("Store4", "RR", "keMSAsoStore4-RR", "Q3CQ-CC83-RQJW"),
      s("Store4", "FR", "keMSAsoStore4-FR", "Q3CQ-F8FZ-5WQM"),
      s("Store4", "FL", "keMSAsoStore4-FL", "Q3CQ-N33R-4HRJ"),
      s("Store5", "FL", "keMSAsoStore5-FL", "Q3CQ-NZVE-SER4"),
      s("Store5", "FR", "keMSAsoStore5-FR", "Q3CQ-PSLH-WUZN"),
      s("Store5", "RL", "keMSAsoStore5-RL", "Q3CQ-YB99-WZBJ"),
      s("Store5", "RR", "keMSAsoStore5-RR", "Q3CQ-ZE6L-QPYH"),
      s("Store6", "FR", "keMSAsoStore6-FR", "Q3CQ-4E8V-2HPW"),
      s("Store6", "FL", "keMSAsoStore6-FL", "Q3CQ-9M3R-XAF4"),
      s("Store6", "RL", "keMSAsoStore6-RL", "Q3CQ-E8Z3-D4GX"),
      s("Store6", "RR", "keMSAsoStore6-RR", "Q3CQ-LDNL-EVJC"),
      s("Store7", "FL", "keMSAsoStore7-FL", "Q3CQ-4GTL-G37B"),
      s("Store7", "RR", "keMSAsoStore7-RR", "Q3CQ-4LUV-35MX"),
      s("Store7", "RL", "keMSAsoStore7-RL", "Q3CQ-SSD6-KPF2"),
      s("Store7", "FR", "keMSAsoStore7-FR", "Q3CQ-YS7L-5EB2"),
      s("Store8", "RL", "keMSAsoStore8-RL", "Q3CQ-5GR6-3UXB"),
      s("Store8", "FL", "keMSAsoStore8-FL", "Q3CQ-7MFU-KT4W"),
      s("Store8", "FR", "keMSAsoStore8-FR", "Q3CQ-MKF2-PLYR"),
      s("Store8", "RR", "keMSAsoStore8-RR", "Q3CQ-VW4W-DPCX"),
      s("Store9", "FR", "keMSAsoStore9-FR", "Q3CQ-7C62-JSL7"),
      s("Store9", "RR", "keMSAsoStore9-RR", "Q3CQ-M9RL-8RVN"),
      s("Store9", "FL", "keMSAsoStore9-FL", "Q3CQ-TQJE-KM3T"),
      s("Store9", "RL", "keMSAsoStore9-RL", "Q3CQ-V5L7-9NS4"),
      s("Store10", "RL", "keMSAsoStore10-RL", "Q3CQ-9M7Z-WPDT",
        meraki_status: "non_conforming",
        notes:
          "Meraki reports this device as Non-conforming (likely firmware/config). " <>
            "Device-health flag only — never treat as an environmental anomaly."
      ),
      s("Store10", "RR", "keMSAsoStore10-RR", "Q3CQ-F8Y8-BL7W"),
      s("Store10", "FL", "keMSAsoStore10-FL", "Q3CQ-RGR5-SAQ2"),
      s("Store10", "FR", "keMSAsoStore10-FR", "Q3CQ-ZGLJ-TAW3"),
      s("Store11", "RL", "keMSAsoStore11-RL", "Q3CQ-275E-EKX8",
        notes: "Store11 RR corner has no sensor — coverage gap, not a data error."
      ),
      s("Store11", "FR", "keMSAsoStore11-FR", "Q3CQ-KHT4-E4JF"),
      s("Store11", "FL", "keMSAsoStore11-FL", "Q3CQ-MSTC-P35T"),
      s("Store12", "RL", "keMSAsoStore12-RL", "Q3CQ-7DRB-NR98"),
      s("Store12", "RR", "keMSAsoStore12-RR", "Q3CQ-84PC-SGLL"),
      s("Store12", "FL", "keMSAsoStore12-FL", "Q3CQ-RZR3-B847"),
      s("Store12", "FR", "keMSAsoStore12-FR", "Q3CQ-WZGT-DXJE"),
      s("Store13", "single", "keMSAsoStore13", "Q3CQ-DETJ-3Z7V",
        notes:
          "Only one sensor for the whole zone — no corner subdivision, unlike every other store."
      ),
      s("Store14", "01", "keMSAsoStore14-01", "Q3CQ-WTK3-JDZE",
        notes:
          "Store14 uses numeric position suffixes (01-04) instead of compass corners — " <>
            "inconsistent naming versus the other stores."
      ),
      s("Store14", "02", "keMSAsoStore14-02", "Q3CQ-TA6A-LECV"),
      s("Store14", "03", "keMSAsoStore14-03", "Q3CQ-VGW4-JFVJ"),
      s("Store14", "04", "keMSAsoStore14-04", "Q3CQ-7TU4-65GE"),
      s("SRV", "01", "keMSAsoSRV-01", "Q3CQ-SHNB-5L5V",
        notes: "Not food storage — excluded from FSQ threshold scope."
      ),
      s("SRV", "02", "keMSAsoSRV-02", "Q3CQ-2B82-756P",
        notes: "Not food storage — excluded from FSQ threshold scope."
      ),
      s("SE", "checkpoint", "keMSAsoSE1", "Q3CB-9N4K-D33G",
        model: "MT12",
        sensor_type: "water",
        battery_pct: 65,
        notes:
          "Only water/leak sensor sitewide. Status was \"alerting\" with battery 65% at " <>
            "export time — verify current state before relying on it as healthy."
      ),
      s("SE", "checkpoint", "keMSAsoSE01", "Q3CG-VAYR-FHQE",
        model: "MT14",
        battery_pct: 29,
        notes: "Battery 29% at export time — low; verify current level."
      )
    ]
  end

  # Defaults match the bulk of the fleet: MT15 IAQ sensors.
  defp s(zone_name, position, name, serial, opts \\ []) do
    %{
      zone_name: zone_name,
      position: position,
      name: name,
      serial: serial,
      model: Keyword.get(opts, :model, "MT15"),
      sensor_type: Keyword.get(opts, :sensor_type, "iaq"),
      battery_pct: Keyword.get(opts, :battery_pct),
      rssi_dbm: Keyword.get(opts, :rssi_dbm),
      meraki_status: Keyword.get(opts, :meraki_status),
      notes: Keyword.get(opts, :notes)
    }
  end
end
