defmodule Ingestion.ThresholdRules.ThresholdRule do
  @moduledoc """
  A commodity threshold rule, in the FSQ approval workflow.

  Status lifecycle (enforced only via `Ingestion.ThresholdRules`, never by
  updating `status` directly — see that module):

      draft -> pending_fsq_review -> approved
                                   -> draft (rejected / revision requested)
      approved -> retired (superseded by a newer approved version)

  Editing an `approved` rule does not mutate it: `Ingestion.ThresholdRules.
  create_new_version/2` inserts a new `draft` row sharing `family_id` with
  the original, which stays `approved` (and enforced) until the new version
  itself is approved.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(draft pending_fsq_review approved retired)
  @comparators ~w(above below)
  @severities ~w(critical high medium low)

  schema "threshold_rules" do
    field :commodity, :string
    field :trigger_condition, :string
    field :duration_window, :integer
    field :severity, :string
    field :expected_outcome, :string
    field :recommended_action, :string
    field :source_reference, :string
    field :status, :string, default: "draft"
    field :approved_by, :string
    field :approved_at, :utc_datetime
    field :version, :integer, default: 1

    # Machine-evaluable counterpart to `trigger_condition`. A rule breaches
    # when a reading is `comparator` (above/below) `boundary_value`, sustained
    # for `duration_window` seconds. `hysteresis_gap` widens the boundary the
    # *raise* condition must clear so the *clear* condition (the plain
    # `boundary_value`) is comparatively easier to satisfy again — see
    # `Ingestion.RulesEngine.Rule` for the raise/clear boundary math.
    field :comparator, :string, default: "above"
    field :boundary_value, :float, default: 0.0
    field :hysteresis_gap, :float, default: 0.0
    field :rate_of_change_threshold, :float

    field :family_id, :id
    field :previous_version_id, :id

    timestamps(type: :utc_datetime)
  end

  @editable_fields ~w(
    commodity trigger_condition duration_window severity expected_outcome
    recommended_action source_reference comparator boundary_value
    hysteresis_gap rate_of_change_threshold
  )a

  @doc """
  Changeset for the editable content of a rule (never `status`,
  `approved_by`, `approved_at`, `version`, `family_id`, or
  `previous_version_id` — those only change through
  `Ingestion.ThresholdRules`' workflow functions).
  """
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, @editable_fields)
    |> validate_required([
      :commodity,
      :trigger_condition,
      :duration_window,
      :severity,
      :comparator,
      :boundary_value,
      :hysteresis_gap
    ])
    |> validate_inclusion(:comparator, @comparators)
    |> validate_inclusion(:severity, @severities)
    |> validate_number(:duration_window, greater_than_or_equal_to: 0)
    |> validate_number(:hysteresis_gap, greater_than_or_equal_to: 0)
    |> validate_number(:rate_of_change_threshold, greater_than_or_equal_to: 0)
  end

  @doc false
  def statuses, do: @statuses

  @doc false
  def comparators, do: @comparators

  @doc false
  def severities, do: @severities

  # Internal changeset used only by `Ingestion.ThresholdRules` to move a rule
  # between workflow statuses. Not part of the public API: every caller must
  # go through the context so the transition is paired with a `RuleAudit` row
  # in the same transaction.
  @doc false
  def status_changeset(rule, attrs) do
    rule
    |> cast(attrs, [:status, :approved_by, :approved_at])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
  end

  @doc false
  def new_version_changeset(source_rule, attrs) do
    # Fields not present in `attrs` (a partial edit, or none at all) carry
    # over from the source rule rather than failing required-field
    # validation — versioning is "edit some fields", not "start from blank".
    base_attrs =
      Map.new(@editable_fields, fn field ->
        {Atom.to_string(field), Map.fetch!(source_rule, field)}
      end)

    merged_attrs = Map.merge(base_attrs, stringify_keys(attrs))

    %__MODULE__{}
    |> cast(merged_attrs, @editable_fields)
    |> validate_required([
      :commodity,
      :trigger_condition,
      :duration_window,
      :severity,
      :comparator,
      :boundary_value,
      :hysteresis_gap
    ])
    |> validate_inclusion(:comparator, @comparators)
    |> validate_inclusion(:severity, @severities)
    |> validate_number(:duration_window, greater_than_or_equal_to: 0)
    |> validate_number(:hysteresis_gap, greater_than_or_equal_to: 0)
    |> validate_number(:rate_of_change_threshold, greater_than_or_equal_to: 0)
    |> put_change(:status, "draft")
    |> put_change(:version, source_rule.version + 1)
    |> put_change(:family_id, source_rule.family_id || source_rule.id)
    |> put_change(:previous_version_id, source_rule.id)
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
