defmodule Ingestion.Fixtures do
  @moduledoc """
  Synthetic time-series and rule fixtures for tests. Replaces the old
  Python mock sensor generator — these build small, deterministic
  `Ingestion.RulesEngine.Evaluator.reading/0` lists and `ThresholdRule`
  rows directly in ExUnit.
  """

  alias Ingestion.Incidents
  alias Ingestion.Inventory.{Sensor, Zone}
  alias Ingestion.Repo
  alias Ingestion.RulesEngine.Rule
  alias Ingestion.ThresholdRules
  alias Ingestion.ThresholdRules.ThresholdRule

  @doc """
  Builds a reading window, most-recent-first, starting `values` (oldest
  first, as given) one second apart, ending at `now` (default:
  `DateTime.utc_now/0`). `values` should therefore be given oldest-first,
  e.g. `series([10.0, 10.5, 11.0])` puts `11.0` most recently.
  """
  def series(values, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    step_seconds = Keyword.get(opts, :step_seconds, 1)
    count = length(values)

    values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      seconds_ago = (count - 1 - index) * step_seconds
      %{value: value, recorded_at: DateTime.add(now, -seconds_ago, :second)}
    end)
    |> Enum.reverse()
  end

  @doc "A plain evaluable `Rule` struct, no database involved."
  def rule(attrs \\ []) do
    struct!(
      Rule,
      Map.merge(
        %{
          id: System.unique_integer([:positive]),
          commodity: "frozen_food",
          comparator: :above,
          boundary_value: 8.0,
          hysteresis_gap: 1.0,
          duration_window: 300,
          rate_of_change_threshold: nil,
          severity: "critical"
        },
        Map.new(attrs)
      )
    )
  end

  @doc "Valid `ThresholdRule` changeset attrs, as placeholder as the seeds — no real threshold values."
  def threshold_rule_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        commodity: "frozen_food",
        trigger_condition: "PLACEHOLDER — pending FSQ sign-off",
        duration_window: 300,
        severity: "critical",
        comparator: "above",
        boundary_value: 0.0,
        hysteresis_gap: 0.0
      },
      attrs
    )
  end

  @doc "Inserts a `draft` ThresholdRule via the real context (so it gets its audit trail)."
  def insert_draft_rule!(attrs \\ %{}, actor \\ "test-analyst") do
    {:ok, rule} = ThresholdRules.create_draft(threshold_rule_attrs(attrs), actor)
    rule
  end

  @doc "Inserts a rule and drives it all the way to `approved` via the real workflow."
  def insert_approved_rule!(attrs \\ %{}, actor \\ "test-fsq") do
    rule = insert_draft_rule!(attrs, actor)
    {:ok, rule} = ThresholdRules.submit_for_review(rule, actor)
    {:ok, rule} = ThresholdRules.approve(rule, actor)
    rule
  end

  @doc "A `ThresholdRule` struct that has never touched the database, at a given status, for unit tests."
  def unsaved_threshold_rule(status) do
    %ThresholdRule{
      id: System.unique_integer([:positive]),
      commodity: "frozen_food",
      comparator: "above",
      boundary_value: 8.0,
      hysteresis_gap: 1.0,
      duration_window: 300,
      severity: "critical",
      status: status
    }
  end

  ## Inventory

  @doc "Inserts a Zone. Defaults to an in-scope storage zone with a confirmed commodity."
  def insert_zone!(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      name: "TestZone#{unique}",
      zone_type: "storage",
      commodity: "frozen_food"
    }

    %Zone{}
    |> Zone.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  @doc "Inserts a Sensor, creating a zone for it unless one is given."
  def insert_sensor!(attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    {zone, attrs} = Map.pop_lazy(attrs, :zone, fn -> insert_zone!() end)

    defaults = %{
      name: "keTestSensor#{unique}",
      serial: "TEST-#{unique}",
      model: "MT15",
      sensor_type: "iaq",
      position: "FL",
      zone_id: zone.id
    }

    %Sensor{}
    |> Sensor.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
    |> Repo.preload(:zone)
  end

  ## Incidents

  @doc """
  Inserts an Incident directly via the context, defaulting to a fresh
  sensor and an approved rule so the FKs are real.
  """
  def insert_incident!(attrs \\ %{}) do
    {sensor, attrs} = Map.pop_lazy(attrs, :sensor, fn -> insert_sensor!() end)

    {rule, attrs} =
      Map.pop_lazy(attrs, :rule, fn ->
        insert_approved_rule!(%{commodity: sensor.zone.commodity || "frozen_food"})
      end)

    defaults = %{
      sensor_id: sensor.id,
      rule_id: rule.id,
      severity: rule.severity,
      status: "new",
      trigger_status: "breach",
      triggered_at: DateTime.utc_now() |> DateTime.truncate(:second),
      reading_value: 9.5,
      observed_duration_seconds: 420
    }

    {:ok, incident} = Incidents.create_incident(Map.merge(defaults, attrs))
    incident
  end
end
