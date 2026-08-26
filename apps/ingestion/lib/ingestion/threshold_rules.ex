defmodule Ingestion.ThresholdRules do
  @moduledoc """
  The FSQ rule-approval workflow, enforced in code.

  This module is the *only* place allowed to change a `ThresholdRule`'s
  `status`. Every function that does so wraps the rule update and a
  `RuleAudit` insert in one `Ecto.Multi` transaction, so a status change
  without an audit row is not possible through this API — and nothing
  outside this module ever calls `Repo.update` on a rule's status directly.

  `list_approved_rules_for_commodity/1` is the single read path the rules
  engine uses to find rules to evaluate; it is hard-filtered to
  `status == "approved"` in the query itself, and its results are only ever
  handed to `Ingestion.RulesEngine.Rule.from_schema!/1`, which independently
  re-checks status and raises for anything else. See
  `Ingestion.RulesEngine.Rule` for that second layer of enforcement.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Ingestion.Repo
  alias Ingestion.ThresholdRules.{RuleAudit, ThresholdRule}

  ## Reads

  @doc "Lists the current (highest-version) rule in every family, newest first."
  @spec list_latest_rules() :: [ThresholdRule.t()]
  def list_latest_rules do
    ThresholdRule
    |> Repo.all()
    |> Enum.group_by(&family_key/1)
    |> Enum.map(fn {_family, versions} -> Enum.max_by(versions, & &1.version) end)
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  @doc "Fetches a single rule by id, raising if missing."
  @spec get_rule!(integer()) :: ThresholdRule.t()
  def get_rule!(id), do: Repo.get!(ThresholdRule, id)

  @doc "Lists every version in `rule`'s family, oldest first."
  @spec list_versions(ThresholdRule.t()) :: [ThresholdRule.t()]
  def list_versions(%ThresholdRule{} = rule) do
    key = family_key(rule)

    from(r in ThresholdRule, where: r.id == ^key or r.family_id == ^key, order_by: r.version)
    |> Repo.all()
  end

  @doc "Lists just `rule`'s own audit trail (not its whole version family), newest first."
  @spec list_audits(ThresholdRule.t()) :: [RuleAudit.t()]
  def list_audits(%ThresholdRule{id: id}) do
    # `id` breaks ties for audits inserted within the same second —
    # `inserted_at` is second-precision (`utc_datetime`), so two audits on
    # the same rule can otherwise sort ambiguously.
    from(a in RuleAudit, where: a.rule_id == ^id, order_by: [desc: a.inserted_at, desc: a.id])
    |> Repo.all()
  end

  @doc "Lists the audit trail across every version in `rule`'s family, newest first."
  @spec list_family_audits(ThresholdRule.t()) :: [RuleAudit.t()]
  def list_family_audits(%ThresholdRule{} = rule) do
    rule_ids = rule |> list_versions() |> Enum.map(& &1.id)

    from(a in RuleAudit,
      where: a.rule_id in ^rule_ids,
      order_by: [desc: a.inserted_at, desc: a.id]
    )
    |> Repo.all()
  end

  @doc """
  The rules-engine read path: every currently `approved` rule for a
  commodity. Never returns `draft`, `pending_fsq_review`, or `retired` rows
  — the `status == "approved"` filter is in the query, not applied after
  the fact.
  """
  @spec list_approved_rules_for_commodity(String.t()) :: [ThresholdRule.t()]
  def list_approved_rules_for_commodity(commodity) do
    from(r in ThresholdRule, where: r.status == "approved" and r.commodity == ^commodity)
    |> Repo.all()
  end

  ## Workflow

  @doc "Creates a brand-new rule family, starting life as `draft`."
  @spec create_draft(map(), String.t()) :: {:ok, ThresholdRule.t()} | {:error, Ecto.Changeset.t()}
  def create_draft(attrs, actor) do
    Multi.new()
    |> Multi.insert(:rule, ThresholdRule.changeset(%ThresholdRule{}, attrs))
    |> Multi.update(:rule_with_family, fn %{rule: rule} ->
      Ecto.Changeset.change(rule, family_id: rule.family_id || rule.id)
    end)
    |> Multi.insert(:audit, fn %{rule_with_family: rule} ->
      audit_changeset(rule, "created", nil, "draft", actor, nil)
    end)
    |> Repo.transaction()
    |> unwrap(:rule_with_family)
  end

  @doc """
  Edits a rule. Dispatches by current status: a `draft` is updated in
  place; an `approved` rule is versioned (see `create_new_version/3`).
  Anything else (`pending_fsq_review`, `retired`) cannot be edited.
  """
  @spec edit(ThresholdRule.t(), map(), String.t()) ::
          {:ok, ThresholdRule.t()} | {:error, Ecto.Changeset.t() | :not_editable}
  def edit(%ThresholdRule{status: "draft"} = rule, attrs, actor),
    do: update_draft(rule, attrs, actor)

  def edit(%ThresholdRule{status: "approved"} = rule, attrs, actor),
    do: create_new_version(rule, attrs, actor)

  def edit(%ThresholdRule{}, _attrs, _actor), do: {:error, :not_editable}

  @doc "Updates a `draft` rule's content in place. Logs an `edited` audit entry."
  @spec update_draft(ThresholdRule.t(), map(), String.t()) ::
          {:ok, ThresholdRule.t()} | {:error, Ecto.Changeset.t() | :not_editable}
  def update_draft(%ThresholdRule{status: "draft"} = rule, attrs, actor) do
    Multi.new()
    |> Multi.update(:rule, ThresholdRule.changeset(rule, attrs))
    |> Multi.insert(:audit, fn %{rule: rule} ->
      audit_changeset(rule, "edited", "draft", "draft", actor, nil)
    end)
    |> Repo.transaction()
    |> unwrap(:rule)
  end

  def update_draft(%ThresholdRule{}, _attrs, _actor), do: {:error, :not_editable}

  @doc """
  Versions an `approved` rule: inserts a new `draft` row sharing its
  family, incrementing `version`. The source rule is left untouched —
  still `approved`, still returned by `list_approved_rules_for_commodity/1`
  — until the new version is itself approved (see `approve/3`).
  """
  @spec create_new_version(ThresholdRule.t(), map(), String.t()) ::
          {:ok, ThresholdRule.t()} | {:error, Ecto.Changeset.t() | :not_editable}
  def create_new_version(%ThresholdRule{status: "approved"} = rule, attrs, actor) do
    Multi.new()
    |> Multi.run(:source, fn repo, _ ->
      if rule.family_id do
        {:ok, rule}
      else
        rule |> Ecto.Changeset.change(family_id: rule.id) |> repo.update()
      end
    end)
    |> Multi.insert(:new_version, fn %{source: source} ->
      ThresholdRule.new_version_changeset(source, attrs)
    end)
    |> Multi.insert(:audit, fn %{new_version: new_version} ->
      audit_changeset(new_version, "created", nil, "draft", actor, "New version of ##{rule.id}")
    end)
    |> Repo.transaction()
    |> unwrap(:new_version)
  end

  def create_new_version(%ThresholdRule{}, _attrs, _actor), do: {:error, :not_editable}

  @doc "Moves a `draft` rule to `pending_fsq_review`."
  @spec submit_for_review(ThresholdRule.t(), String.t()) ::
          {:ok, ThresholdRule.t()} | {:error, Ecto.Changeset.t() | :invalid_transition}
  def submit_for_review(%ThresholdRule{status: "draft"} = rule, actor) do
    transition(rule, "pending_fsq_review", actor, "submitted_for_review", nil)
  end

  def submit_for_review(%ThresholdRule{}, _actor), do: {:error, :invalid_transition}

  @doc """
  Approves a `pending_fsq_review` rule. If it belongs to a family with a
  previously `approved` version, that version is atomically retired
  (`superseded`) in the same transaction, so exactly one version per
  family is ever `approved` (and therefore evaluated) at a time.
  """
  @spec approve(ThresholdRule.t(), String.t(), String.t() | nil) ::
          {:ok, ThresholdRule.t()} | {:error, Ecto.Changeset.t() | :invalid_transition}
  def approve(rule, actor, comment \\ nil)

  def approve(%ThresholdRule{status: "pending_fsq_review"} = rule, actor, comment) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update(:rule, fn _ ->
      ThresholdRule.status_changeset(rule, %{
        status: "approved",
        approved_by: actor,
        approved_at: now
      })
    end)
    |> Multi.insert(:audit, fn %{rule: rule} ->
      audit_changeset(rule, "approved", "pending_fsq_review", "approved", actor, comment)
    end)
    |> Multi.run(:supersede, fn repo, %{rule: rule} ->
      supersede_prior_version(repo, rule, actor)
    end)
    |> Repo.transaction()
    |> unwrap(:rule)
  end

  def approve(%ThresholdRule{}, _actor, _comment), do: {:error, :invalid_transition}

  @doc "Rejects a `pending_fsq_review` rule back to `draft`. `comment` is required."
  @spec reject(ThresholdRule.t(), String.t(), String.t()) ::
          {:ok, ThresholdRule.t()} | {:error, Ecto.Changeset.t() | :invalid_transition}
  def reject(%ThresholdRule{status: "pending_fsq_review"} = rule, actor, comment) do
    transition(rule, "draft", actor, "rejected", comment)
  end

  def reject(%ThresholdRule{}, _actor, _comment), do: {:error, :invalid_transition}

  @doc """
  Sends a `pending_fsq_review` rule back to `draft` requesting changes,
  distinct from an outright `reject` in the audit trail. `comment` is
  required.
  """
  @spec request_revision(ThresholdRule.t(), String.t(), String.t()) ::
          {:ok, ThresholdRule.t()} | {:error, Ecto.Changeset.t() | :invalid_transition}
  def request_revision(%ThresholdRule{status: "pending_fsq_review"} = rule, actor, comment) do
    transition(rule, "draft", actor, "revision_requested", comment)
  end

  def request_revision(%ThresholdRule{}, _actor, _comment), do: {:error, :invalid_transition}

  @doc "Manually retires an `approved` rule (no replacement version required)."
  @spec retire(ThresholdRule.t(), String.t(), String.t() | nil) ::
          {:ok, ThresholdRule.t()} | {:error, Ecto.Changeset.t() | :invalid_transition}
  def retire(rule, actor, comment \\ nil)

  def retire(%ThresholdRule{status: "approved"} = rule, actor, comment) do
    transition(rule, "retired", actor, "retired", comment)
  end

  def retire(%ThresholdRule{}, _actor, _comment), do: {:error, :invalid_transition}

  ## Helpers

  defp family_key(%ThresholdRule{family_id: nil, id: id}), do: id
  defp family_key(%ThresholdRule{family_id: family_id}), do: family_id

  defp supersede_prior_version(_repo, %ThresholdRule{previous_version_id: nil}, _actor),
    do: {:ok, nil}

  defp supersede_prior_version(
         repo,
         %ThresholdRule{previous_version_id: prev_id} = new_rule,
         actor
       ) do
    case repo.get(ThresholdRule, prev_id) do
      %ThresholdRule{status: "approved"} = prior ->
        changeset = ThresholdRule.status_changeset(prior, %{status: "retired"})

        with {:ok, retired} <- repo.update(changeset) do
          comment = "Superseded by version #{new_rule.version} (##{new_rule.id})"

          audit_changeset(retired, "superseded", "approved", "retired", actor, comment)
          |> repo.insert()
        end

      _ ->
        {:ok, nil}
    end
  end

  defp transition(rule, to_status, actor, action, comment) do
    from_status = rule.status

    Multi.new()
    |> Multi.update(:rule, ThresholdRule.status_changeset(rule, %{status: to_status}))
    |> Multi.insert(:audit, fn %{rule: updated_rule} ->
      audit_changeset(updated_rule, action, from_status, to_status, actor, comment)
    end)
    |> Repo.transaction()
    |> unwrap(:rule)
  end

  defp audit_changeset(rule, action, from_status, to_status, actor, comment) do
    RuleAudit.changeset(%RuleAudit{}, %{
      rule_id: rule.id,
      action: action,
      from_status: from_status,
      to_status: to_status,
      actor: actor,
      comment: comment
    })
  end

  defp unwrap({:ok, results}, key), do: {:ok, Map.fetch!(results, key)}

  defp unwrap({:error, _failed_op, changeset_or_reason, _changes}, _key),
    do: {:error, changeset_or_reason}
end
