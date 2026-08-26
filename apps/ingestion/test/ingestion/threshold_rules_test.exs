defmodule Ingestion.ThresholdRulesTest do
  use Ingestion.DataCase, async: true

  import Ingestion.Fixtures

  alias Ingestion.ThresholdRules

  describe "create_draft/2" do
    test "starts a rule as draft and logs a 'created' audit entry" do
      assert {:ok, rule} = ThresholdRules.create_draft(threshold_rule_attrs(), "j.analyst")
      assert rule.status == "draft"
      assert rule.version == 1

      [audit] = ThresholdRules.list_family_audits(rule)
      assert audit.action == "created"
      assert audit.to_status == "draft"
      assert audit.actor == "j.analyst"
      assert %DateTime{} = audit.inserted_at
    end

    test "rejects invalid attrs" do
      assert {:error, changeset} = ThresholdRules.create_draft(%{}, "j.analyst")
      refute changeset.valid?
    end
  end

  describe "the FSQ review workflow" do
    setup do
      {:ok, rule} = ThresholdRules.create_draft(threshold_rule_attrs(), "j.analyst")
      %{rule: rule}
    end

    test "submit_for_review moves draft -> pending_fsq_review and is audited", %{rule: rule} do
      assert {:ok, submitted} = ThresholdRules.submit_for_review(rule, "j.analyst")
      assert submitted.status == "pending_fsq_review"

      audits = ThresholdRules.list_family_audits(submitted)
      assert Enum.any?(audits, &(&1.action == "submitted_for_review" and &1.actor == "j.analyst"))
    end

    test "approve moves pending_fsq_review -> approved, stamping approver and time", %{rule: rule} do
      {:ok, submitted} = ThresholdRules.submit_for_review(rule, "j.analyst")

      assert {:ok, approved} = ThresholdRules.approve(submitted, "m.fsq", "looks good")
      assert approved.status == "approved"
      assert approved.approved_by == "m.fsq"
      assert %DateTime{} = approved.approved_at

      audits = ThresholdRules.list_family_audits(approved)
      approval = Enum.find(audits, &(&1.action == "approved"))
      assert approval.actor == "m.fsq"
      assert approval.comment == "looks good"
      assert approval.from_status == "pending_fsq_review"
      assert approval.to_status == "approved"
    end

    test "reject requires a comment and moves pending_fsq_review -> draft", %{rule: rule} do
      {:ok, submitted} = ThresholdRules.submit_for_review(rule, "j.analyst")

      assert {:error, changeset} = ThresholdRules.reject(submitted, "m.fsq", "")
      refute changeset.valid?

      assert {:ok, rejected} =
               ThresholdRules.reject(submitted, "m.fsq", "boundary is unrealistic")

      assert rejected.status == "draft"

      audits = ThresholdRules.list_family_audits(rejected)
      rejection = Enum.find(audits, &(&1.action == "rejected"))
      assert rejection.actor == "m.fsq"
      assert rejection.comment == "boundary is unrealistic"
    end

    test "request_revision requires a comment, moves to draft, and is distinct from reject", %{
      rule: rule
    } do
      {:ok, submitted} = ThresholdRules.submit_for_review(rule, "j.analyst")

      assert {:error, _changeset} = ThresholdRules.request_revision(submitted, "m.fsq", "")

      assert {:ok, revised} =
               ThresholdRules.request_revision(
                 submitted,
                 "m.fsq",
                 "please add a source reference"
               )

      assert revised.status == "draft"

      audits = ThresholdRules.list_family_audits(revised)
      assert Enum.any?(audits, &(&1.action == "revision_requested"))
      refute Enum.any?(audits, &(&1.action == "rejected"))
    end

    test "approve, reject, and request_revision are no-ops on a rule that is still draft", %{
      rule: rule
    } do
      assert {:error, :invalid_transition} = ThresholdRules.approve(rule, "m.fsq")
      assert {:error, :invalid_transition} = ThresholdRules.reject(rule, "m.fsq", "no")
      assert {:error, :invalid_transition} = ThresholdRules.request_revision(rule, "m.fsq", "no")
    end
  end

  describe "editing and versioning" do
    test "editing a draft updates it in place and logs an 'edited' audit entry" do
      rule = insert_draft_rule!()

      assert {:ok, edited} =
               ThresholdRules.edit(rule, %{trigger_condition: "updated wording"}, "j.analyst")

      assert edited.id == rule.id
      assert edited.trigger_condition == "updated wording"
      assert edited.version == 1

      audits = ThresholdRules.list_family_audits(edited)
      assert Enum.any?(audits, &(&1.action == "edited"))
    end

    test "editing an approved rule creates a new draft version without touching the approved one" do
      approved = insert_approved_rule!()

      assert {:ok, new_version} =
               ThresholdRules.edit(
                 approved,
                 %{trigger_condition: "tightened wording"},
                 "j.analyst"
               )

      assert new_version.status == "draft"
      assert new_version.version == approved.version + 1
      assert new_version.family_id == approved.id

      # the original approved rule is untouched and still approved
      still_approved = ThresholdRules.get_rule!(approved.id)
      assert still_approved.status == "approved"

      # both versions show up in family history
      versions = ThresholdRules.list_versions(new_version)
      assert length(versions) == 2
      assert Enum.map(versions, & &1.status) |> Enum.sort() == ["approved", "draft"]
    end

    test "the prior approved version stays evaluable until the new version is itself approved" do
      approved = insert_approved_rule!(%{commodity: "chilled_pharma"})
      {:ok, new_version} = ThresholdRules.edit(approved, %{}, "j.analyst")

      # only the original is approved right now
      assert [only] = ThresholdRules.list_approved_rules_for_commodity("chilled_pharma")
      assert only.id == approved.id

      {:ok, submitted} = ThresholdRules.submit_for_review(new_version, "j.analyst")
      assert {:ok, newly_approved} = ThresholdRules.approve(submitted, "m.fsq")

      # approving the new version supersedes (retires) the old one
      superseded = ThresholdRules.get_rule!(approved.id)
      assert superseded.status == "retired"

      assert [only] = ThresholdRules.list_approved_rules_for_commodity("chilled_pharma")
      assert only.id == newly_approved.id

      audits = ThresholdRules.list_family_audits(newly_approved)
      assert Enum.any?(audits, &(&1.action == "superseded" and &1.rule_id == approved.id))
    end

    test "a pending_fsq_review rule cannot be edited" do
      rule = insert_draft_rule!()
      {:ok, pending} = ThresholdRules.submit_for_review(rule, "j.analyst")

      assert {:error, :not_editable} = ThresholdRules.edit(pending, %{}, "j.analyst")
    end
  end

  describe "list_approved_rules_for_commodity/1" do
    test "only ever returns approved rules" do
      _draft = insert_draft_rule!(%{commodity: "ambient_grain"})
      approved = insert_approved_rule!(%{commodity: "ambient_grain"})

      other_draft = insert_draft_rule!(%{commodity: "ambient_grain"})
      {:ok, other_pending} = ThresholdRules.submit_for_review(other_draft, "j.analyst")

      results = ThresholdRules.list_approved_rules_for_commodity("ambient_grain")

      assert Enum.map(results, & &1.id) == [approved.id]
      refute other_pending.status == "approved"
    end

    test "does not return rules for a different commodity" do
      insert_approved_rule!(%{commodity: "frozen_food"})

      assert ThresholdRules.list_approved_rules_for_commodity("chilled_dairy") == []
    end
  end
end
