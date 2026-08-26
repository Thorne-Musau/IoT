defmodule WarehouseWeb.RuleLiveTest do
  use WarehouseWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ingestion.Fixtures

  alias Ingestion.ThresholdRules

  describe "listing" do
    test "renders drafts with the neutral status badge", %{conn: conn} do
      rule = insert_draft_rule!(%{commodity: "listing_test_frozen"})

      {:ok, _view, html} = live(conn, ~p"/rules")

      assert html =~ "Rule Management"
      assert html =~ rule.commodity
      assert html =~ "Draft"
      assert html =~ "bg-neutral-100"
    end

    test "shows an empty state with no rules", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/rules")
      assert html =~ "No threshold rules yet"
    end
  end

  describe "creating a rule" do
    test "the new-rule form creates a draft", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rules/new")

      assert view
             |> form("#rule-form", %{
               "actor" => "j.analyst",
               "threshold_rule" => %{
                 "commodity" => "new_rule_test_commodity",
                 "trigger_condition" => "PLACEHOLDER pending FSQ",
                 "duration_window" => "300",
                 "severity" => "critical",
                 "comparator" => "above",
                 "boundary_value" => "0.0",
                 "hysteresis_gap" => "0.0"
               }
             })
             |> render_submit()

      assert_redirect(view, ~p"/rules")

      {:ok, _view, html} = live(conn, ~p"/rules")
      assert html =~ "new_rule_test_commodity"
    end

    test "rejects an incomplete form with validation errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rules/new")

      html =
        view
        |> form("#rule-form", %{"actor" => "j.analyst", "threshold_rule" => %{"commodity" => ""}})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end
  end

  describe "the FSQ workflow, driven through the live UI" do
    test "moves a rule draft -> pending -> approved", %{conn: conn} do
      rule = insert_draft_rule!(%{commodity: "workflow_test_commodity"})

      {:ok, view, _html} = live(conn, ~p"/rules")

      html =
        render_submit(view, "submit_for_review", %{
          "rule_id" => to_string(rule.id),
          "actor" => "j.analyst"
        })

      assert html =~ "Pending FSQ review"
      assert html =~ "bg-warning-100"

      html =
        render_submit(view, "review_decision", %{
          "rule_id" => to_string(rule.id),
          "actor" => "m.fsq",
          "decision" => "approve",
          "comment" => ""
        })

      assert html =~ "Approved"
      assert html =~ "bg-success-100"

      assert ThresholdRules.get_rule!(rule.id).status == "approved"
    end

    test "rejecting without a comment fails; rejecting with one returns the rule to draft with a danger note",
         %{
           conn: conn
         } do
      rule = insert_draft_rule!(%{commodity: "reject_test_commodity"})
      {:ok, pending} = ThresholdRules.submit_for_review(rule, "j.analyst")

      {:ok, view, _html} = live(conn, ~p"/rules")

      render_submit(view, "review_decision", %{
        "rule_id" => to_string(pending.id),
        "actor" => "m.fsq",
        "decision" => "reject",
        "comment" => ""
      })

      assert ThresholdRules.get_rule!(pending.id).status == "pending_fsq_review"

      html =
        render_submit(view, "review_decision", %{
          "rule_id" => to_string(pending.id),
          "actor" => "m.fsq",
          "decision" => "reject",
          "comment" => "boundary needs FSQ sign-off first"
        })

      assert html =~ "Draft"
      assert html =~ "bg-danger-100"
      assert html =~ "boundary needs FSQ sign-off first"
      assert ThresholdRules.get_rule!(pending.id).status == "draft"
    end

    test "request_revision is distinct from reject in the rendered audit trail", %{conn: conn} do
      rule = insert_draft_rule!(%{commodity: "revision_test_commodity"})
      {:ok, pending} = ThresholdRules.submit_for_review(rule, "j.analyst")

      {:ok, view, _html} = live(conn, ~p"/rules")

      render_submit(view, "review_decision", %{
        "rule_id" => to_string(pending.id),
        "actor" => "m.fsq",
        "decision" => "request_revision",
        "comment" => "please tighten the wording"
      })

      html = render_click(view, "toggle_history", %{"id" => to_string(pending.id)})

      assert html =~ "revision_requested"
      refute html =~ "rejected ("
    end
  end

  describe "editing and version history" do
    test "editing an approved rule creates a new draft version, and history shows both", %{
      conn: conn
    } do
      approved = insert_approved_rule!(%{commodity: "history_test_commodity"})

      {:ok, view, _html} = live(conn, ~p"/rules/#{approved.id}/edit")

      view
      |> form("#rule-form", %{
        "actor" => "j.analyst",
        "threshold_rule" => %{"trigger_condition" => "tightened wording, still pending FSQ"}
      })
      |> render_submit()

      assert_redirect(view, ~p"/rules")

      {:ok, view, html} = live(conn, ~p"/rules")

      # the list shows the newest version per family (the new draft) as the
      # row, not the still-approved original — that's what "editing an
      # approved rule creates a new version without deactivating the
      # currently-approved one" means for the list view
      assert html =~ "Draft"

      latest =
        Enum.find(ThresholdRules.list_latest_rules(), &(&1.commodity == "history_test_commodity"))

      assert latest.status == "draft"

      html = render_click(view, "toggle_history", %{"id" => to_string(latest.id)})

      assert html =~ "v1"
      assert html =~ "v2"
      assert html =~ "Approved"
      assert html =~ "Draft"

      # the approved version is still the one the engine would evaluate
      assert ThresholdRules.get_rule!(approved.id).status == "approved"
    end
  end
end
