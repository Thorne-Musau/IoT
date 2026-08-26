defmodule Ingestion.ThresholdRules.RuleAudit do
  @moduledoc """
  An immutable audit-trail entry for a single threshold-rule status change.

  Every transition a rule goes through (created, submitted for review,
  approved, rejected, revision requested, superseded on approval of a newer
  version) is recorded here with the actor, timestamp, and comment. This is
  the audit trail — rows are never updated or deleted by application code.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @actions ~w(
    created edited submitted_for_review approved rejected revision_requested
    superseded retired
  )

  schema "rule_audits" do
    field :action, :string
    field :from_status, :string
    field :to_status, :string
    field :actor, :string
    field :comment, :string

    belongs_to :rule, Ingestion.ThresholdRules.ThresholdRule

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(audit, attrs) do
    audit
    |> cast(attrs, [:action, :from_status, :to_status, :actor, :comment, :rule_id])
    |> validate_required([:action, :to_status, :actor, :rule_id])
    |> validate_inclusion(:action, @actions)
    |> validate_length(:actor, min: 1)
    |> require_comment_for_feedback_actions()
  end

  # Rejection and revision requests exist to give the drafting analyst
  # something actionable; a comment-less rejection would defeat the point.
  defp require_comment_for_feedback_actions(changeset) do
    if get_field(changeset, :action) in ["rejected", "revision_requested"] do
      changeset
      |> validate_required([:comment])
      |> validate_length(:comment, min: 1)
    else
      changeset
    end
  end
end
