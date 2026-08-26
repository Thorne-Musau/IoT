# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Seeds a handful of example threshold rules for local Rule Management UI
# testing. Every one of these is left as `draft` on purpose: FSQ has not
# signed off on any real threshold values yet, so every numeric field here
# is a clearly-labeled placeholder, not a value anyone should trust or
# evaluate against.

alias Ingestion.Inventory
alias Ingestion.ThresholdRules

# --- Physical inventory: WFP Kenya's real Meraki fleet -------------------
#
# Idempotent (zones keyed on name, sensors on serial). Every zone's
# `commodity` is left nil on purpose — see Ingestion.Inventory.SeedData.
{zone_count, sensor_count} = Inventory.seed_real_inventory!()
IO.puts("Seeded #{zone_count} zones and #{sensor_count} sensors from the Meraki inventory.")

seed_actor = "seed-script"

rules = [
  %{
    commodity: "frozen_food",
    trigger_condition:
      "PLACEHOLDER — FSQ has not confirmed a real boundary yet. Draft intent: " <>
        "temperature sustained above the freezer excursion threshold.",
    duration_window: 900,
    severity: "critical",
    comparator: "above",
    boundary_value: 0.0,
    hysteresis_gap: 0.0,
    rate_of_change_threshold: nil,
    expected_outcome: "PLACEHOLDER — pending FSQ input on acceptable excursion duration.",
    recommended_action: "PLACEHOLDER — pending FSQ input.",
    source_reference: "PLACEHOLDER — cite the FSQ cold-chain SOP once assigned."
  },
  %{
    commodity: "chilled_dairy",
    trigger_condition:
      "PLACEHOLDER — FSQ has not confirmed a real boundary yet. Draft intent: " <>
        "temperature trending upward toward the chilled-storage ceiling.",
    duration_window: 600,
    severity: "medium",
    comparator: "above",
    boundary_value: 0.0,
    hysteresis_gap: 0.0,
    rate_of_change_threshold: 0.0,
    expected_outcome: "PLACEHOLDER — pending FSQ input.",
    recommended_action: "PLACEHOLDER — pending FSQ input.",
    source_reference: "PLACEHOLDER — pending FSQ input."
  },
  %{
    commodity: "ambient_grain",
    trigger_condition:
      "PLACEHOLDER — FSQ has not confirmed a real boundary yet. Draft intent: " <>
        "humidity sustained below the ambient-storage floor (risk of pest/mold conditions " <>
        "at the other end of the band).",
    duration_window: 1800,
    severity: "high",
    comparator: "below",
    boundary_value: 0.0,
    hysteresis_gap: 0.0,
    rate_of_change_threshold: nil,
    expected_outcome: "PLACEHOLDER — pending FSQ input.",
    recommended_action: "PLACEHOLDER — pending FSQ input.",
    source_reference: "PLACEHOLDER — pending FSQ input."
  }
]

# Idempotent: skip a commodity that already has a seeded rule, so re-running
# `mix run priv/repo/seeds.exs` does not pile up duplicate drafts.
already_seeded =
  ThresholdRules.list_latest_rules()
  |> Enum.map(& &1.commodity)
  |> MapSet.new()

Enum.each(rules, fn attrs ->
  if MapSet.member?(already_seeded, attrs.commodity) do
    IO.puts("Draft rule for #{attrs.commodity} already present — skipping.")
  else
    case ThresholdRules.create_draft(attrs, seed_actor) do
      {:ok, rule} ->
        IO.puts("Seeded draft rule ##{rule.id} (#{rule.commodity}) — needs FSQ review.")

      {:error, changeset} ->
        IO.warn("Failed to seed rule for #{attrs.commodity}: #{inspect(changeset.errors)}")
    end
  end
end)
