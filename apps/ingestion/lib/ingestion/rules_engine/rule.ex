defmodule Ingestion.RulesEngine.Rule do
  @moduledoc """
  A plain, evaluable rule. The *only* way to obtain one is
  `from_schema!/1`, which raises unless the source `ThresholdRule` is
  `approved`.

  This is a deliberate second enforcement layer on top of
  `Ingestion.ThresholdRules.list_approved_rules_for_commodity/1`'s query
  filter: `Ingestion.RulesEngine.Evaluator` only accepts a `%Rule{}`, never
  a raw `ThresholdRule` schema struct, so there is no code path — a future
  refactor, a differently-filtered query, a hand-built struct — that can
  hand the evaluator a rule the engine has not itself verified is
  `approved`.
  """

  @enforce_keys [:id, :comparator, :boundary_value, :hysteresis_gap, :duration_window, :severity]
  defstruct [
    :id,
    :commodity,
    :comparator,
    :boundary_value,
    :hysteresis_gap,
    :duration_window,
    :rate_of_change_threshold,
    :severity
  ]

  @type comparator :: :above | :below

  @type t :: %__MODULE__{
          id: integer(),
          commodity: String.t(),
          comparator: comparator(),
          boundary_value: float(),
          hysteresis_gap: float(),
          duration_window: non_neg_integer(),
          rate_of_change_threshold: float() | nil,
          severity: String.t()
        }

  @doc """
  Builds a `Rule` from a `Ingestion.ThresholdRules.ThresholdRule`. Raises
  `ArgumentError` unless the source rule's status is `"approved"` —
  `draft`, `pending_fsq_review`, and `retired` rules can never produce a
  `Rule` and therefore can never be evaluated.
  """
  @spec from_schema!(Ingestion.ThresholdRules.ThresholdRule.t()) :: t()
  def from_schema!(%{status: "approved"} = schema) do
    %__MODULE__{
      id: schema.id,
      commodity: schema.commodity,
      comparator: String.to_existing_atom(schema.comparator),
      boundary_value: schema.boundary_value,
      hysteresis_gap: schema.hysteresis_gap,
      duration_window: schema.duration_window,
      rate_of_change_threshold: schema.rate_of_change_threshold,
      severity: schema.severity
    }
  end

  def from_schema!(%{status: status}) do
    raise ArgumentError,
          "cannot build an evaluable Rule from a #{inspect(status)} threshold rule " <>
            "(only status \"approved\" may be evaluated by the rules engine)"
  end

  @doc """
  The boundary a reading must reach to *raise* an alert — exactly the
  FSQ-approved `boundary_value`, inclusive. `hysteresis_gap` never loosens
  this: the alert-firing point always matches what FSQ approved.
  """
  @spec raise_boundary(t()) :: float()
  def raise_boundary(%__MODULE__{boundary_value: boundary_value}), do: boundary_value

  @doc """
  The boundary a reading must recross, back past `hysteresis_gap` of
  improvement beyond `boundary_value`, to *clear* an alert. Stricter than
  `raise_boundary/1` — this is the only thing `hysteresis_gap` protects
  against flapping on.
  """
  @spec clear_boundary(t()) :: float()
  def clear_boundary(%__MODULE__{comparator: :above} = rule),
    do: rule.boundary_value - rule.hysteresis_gap

  def clear_boundary(%__MODULE__{comparator: :below} = rule),
    do: rule.boundary_value + rule.hysteresis_gap

  @doc """
  Whether `value` is on the breach side of `boundary`, inclusive, for this
  rule's comparator. Used for the *raise* check (against `raise_boundary/1`).
  """
  @spec breached_at?(t(), number(), float()) :: boolean()
  def breached_at?(%__MODULE__{comparator: :above}, value, boundary), do: value >= boundary
  def breached_at?(%__MODULE__{comparator: :below}, value, boundary), do: value <= boundary

  @doc """
  Whether `value` is safely on the clear side of `boundary`, inclusive, for
  this rule's comparator. Used for the *clear* check (against
  `clear_boundary/1`) — deliberately not just `not breached_at?/3`, since
  the raise and clear sides have opposite inclusive edges.
  """
  @spec cleared_at?(t(), number(), float()) :: boolean()
  def cleared_at?(%__MODULE__{comparator: :above}, value, boundary), do: value <= boundary
  def cleared_at?(%__MODULE__{comparator: :below}, value, boundary), do: value >= boundary
end
