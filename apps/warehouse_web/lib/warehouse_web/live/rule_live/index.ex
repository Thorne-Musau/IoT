defmodule WarehouseWeb.RuleLive.Index do
  @moduledoc """
  Rule Management: list, create, edit, and drive threshold rules through
  the FSQ approval workflow (draft -> pending_fsq_review ->
  approved/draft), with version history and the full audit trail.

  Every workflow transition here calls straight into
  `Ingestion.ThresholdRules` — this LiveView never touches a rule's
  `status` field directly, so the audit trail (enforced inside that
  context) cannot be bypassed from the UI.
  """

  use WarehouseWeb, :live_view

  alias Ingestion.ThresholdRules
  alias Ingestion.ThresholdRules.ThresholdRule

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Rule Management", expanded: MapSet.new())
     |> reload_rules()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, rule: nil, form: nil)
  end

  defp apply_action(socket, :new, _params) do
    changeset = ThresholdRule.changeset(%ThresholdRule{}, %{})
    assign(socket, rule: nil, form: to_form(changeset, as: :threshold_rule))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    rule = ThresholdRules.get_rule!(id)
    changeset = ThresholdRule.changeset(rule, %{})
    assign(socket, rule: rule, form: to_form(changeset, as: :threshold_rule))
  end

  ## Events

  @impl true
  def handle_event("validate", %{"threshold_rule" => params}, socket) do
    changeset =
      (socket.assigns.rule || %ThresholdRule{})
      |> ThresholdRule.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :threshold_rule))}
  end

  def handle_event("save", %{"actor" => actor, "threshold_rule" => params}, socket) do
    if blank?(actor) do
      {:noreply, put_flash(socket, :error, "Enter your name before saving.")}
    else
      save_rule(socket, socket.assigns.live_action, params, actor)
    end
  end

  def handle_event("submit_for_review", %{"rule_id" => id, "actor" => actor}, socket) do
    with_actor(actor, fn ->
      ThresholdRules.submit_for_review(ThresholdRules.get_rule!(id), actor)
    end)
    |> respond(socket, "Submitted for FSQ review.")
  end

  def handle_event("review_decision", params, socket) do
    %{"rule_id" => id, "actor" => actor, "decision" => decision} = params
    comment = Map.get(params, "comment", "")
    rule = ThresholdRules.get_rule!(id)

    with_actor(actor, fn -> apply_decision(decision, rule, actor, comment) end)
    |> respond(socket, decision_message(decision))
  end

  def handle_event("retire", %{"rule_id" => id, "actor" => actor} = params, socket) do
    comment = Map.get(params, "comment", "")

    with_actor(actor, fn ->
      ThresholdRules.retire(ThresholdRules.get_rule!(id), actor, blank_to_nil(comment))
    end)
    |> respond(socket, "Rule retired.")
  end

  def handle_event("toggle_history", %{"id" => id}, socket) do
    id = String.to_integer(id)

    expanded =
      if MapSet.member?(socket.assigns.expanded, id) do
        MapSet.delete(socket.assigns.expanded, id)
      else
        MapSet.put(socket.assigns.expanded, id)
      end

    {:noreply, assign(socket, expanded: expanded)}
  end

  ## Create / edit form

  defp save_rule(socket, :new, params, actor) do
    case ThresholdRules.create_draft(params, actor) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Draft rule created.")
         |> push_navigate(to: ~p"/rules")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :threshold_rule))}
    end
  end

  defp save_rule(socket, :edit, params, actor) do
    case ThresholdRules.edit(socket.assigns.rule, params, actor) do
      {:ok, rule} ->
        message =
          if rule.id == socket.assigns.rule.id,
            do: "Draft updated.",
            else: "New draft version (v#{rule.version}) created."

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: ~p"/rules")}

      {:error, :not_editable} ->
        {:noreply,
         socket
         |> put_flash(:error, "This rule can no longer be edited in its current status.")
         |> push_navigate(to: ~p"/rules")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :threshold_rule))}
    end
  end

  defp apply_decision("approve", rule, actor, comment),
    do: ThresholdRules.approve(rule, actor, blank_to_nil(comment))

  defp apply_decision("reject", rule, actor, comment),
    do: ThresholdRules.reject(rule, actor, comment)

  defp apply_decision("request_revision", rule, actor, comment),
    do: ThresholdRules.request_revision(rule, actor, comment)

  defp decision_message("approve"), do: "Rule approved."
  defp decision_message("reject"), do: "Rule rejected back to draft."
  defp decision_message("request_revision"), do: "Revision requested; rule returned to draft."

  defp with_actor(actor, fun) do
    if blank?(actor) do
      {:error, :missing_actor}
    else
      fun.()
    end
  end

  defp respond({:ok, _rule}, socket, success_message) do
    {:noreply,
     socket
     |> put_flash(:info, success_message)
     |> reload_rules()}
  end

  defp respond({:error, :missing_actor}, socket, _success_message) do
    {:noreply, put_flash(socket, :error, "Enter your name before taking this action.")}
  end

  defp respond({:error, :invalid_transition}, socket, _success_message) do
    {:noreply,
     put_flash(socket, :error, "That rule is no longer in a status where this action applies.")}
  end

  defp respond({:error, %Ecto.Changeset{}}, socket, _success_message) do
    {:noreply, put_flash(socket, :error, "A comment is required for that action.")}
  end

  defp reload_rules(socket), do: assign(socket, rules: ThresholdRules.list_latest_rules())

  ## View helpers

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(value) == ""

  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: value)

  defp status_badge_class("approved"), do: "bg-success-100 text-success-700"
  defp status_badge_class("pending_fsq_review"), do: "bg-warning-100 text-warning-700"
  defp status_badge_class(_draft_or_retired), do: "bg-neutral-100 text-neutral-700"

  defp status_label("draft"), do: "Draft"
  defp status_label("pending_fsq_review"), do: "Pending FSQ review"
  defp status_label("approved"), do: "Approved"
  defp status_label("retired"), do: "Retired"

  defp rejection_note(rule) do
    case ThresholdRules.list_audits(rule) do
      [%{action: "rejected"} = audit | _] -> audit
      _ -> nil
    end
  end

  defp format_datetime(nil), do: "—"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center justify-between mb-4">
        <div>
          <h1 class="text-2xl font-bold text-foreground">Rule Management</h1>
          <p class="text-sm text-muted-foreground">
            Duration-gated thresholds go live for the rules engine only once
            <span class="font-semibold text-success-700">approved</span>
            by FSQ.
          </p>
        </div>
        <.link
          navigate={~p"/rules/new"}
          class="rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground hover:bg-primary-700 transition-colors"
        >
          New rule
        </.link>
      </div>

      <p :if={@rules == []} class="text-muted-foreground">
        No threshold rules yet. FSQ hasn't signed off on any thresholds —
        create a draft to start the review workflow.
      </p>

      <ul :if={@rules != []} class="space-y-3">
        <li
          :for={rule <- @rules}
          id={"rule-#{rule.id}"}
          class="rounded-lg border border-border bg-card p-4"
        >
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <span class={[
                  "rounded-md px-2 py-0.5 text-xs font-semibold uppercase tracking-wide",
                  status_badge_class(rule.status)
                ]}>
                  {status_label(rule.status)}
                </span>
                <span class="text-sm font-semibold text-card-foreground">{rule.commodity}</span>
                <span class="text-xs text-muted-foreground">v{rule.version}</span>
              </div>
              <p class="mt-1 text-sm text-card-foreground">{rule.trigger_condition}</p>
              <p class="mt-1 text-xs text-muted-foreground">
                {rule.comparator} {rule.boundary_value} for {rule.duration_window}s · severity: {rule.severity}
              </p>
              <p
                :if={note = rejection_note(rule)}
                class="mt-2 rounded-md bg-danger-100 px-2 py-1 text-xs text-danger-700"
              >
                Rejected by {note.actor}: {note.comment}
              </p>
            </div>

            <div class="flex shrink-0 flex-col items-end gap-2">
              <div class="flex gap-2">
                <.link
                  :if={rule.status in ["draft", "approved"]}
                  navigate={~p"/rules/#{rule.id}/edit"}
                  class="rounded-md border border-border px-3 py-1.5 text-xs font-semibold text-card-foreground hover:bg-muted"
                >
                  {if rule.status == "approved", do: "Edit (new version)", else: "Edit"}
                </.link>
                <button
                  type="button"
                  phx-click="toggle_history"
                  phx-value-id={rule.id}
                  class="rounded-md border border-border px-3 py-1.5 text-xs font-semibold text-card-foreground hover:bg-muted"
                >
                  {if MapSet.member?(@expanded, rule.id), do: "Hide history", else: "History"}
                </button>
              </div>

              <form
                :if={rule.status == "draft"}
                phx-submit="submit_for_review"
                class="flex items-center gap-2"
              >
                <input type="hidden" name="rule_id" value={rule.id} />
                <input
                  type="text"
                  name="actor"
                  placeholder="Your name"
                  required
                  class="w-28 rounded-md border border-input px-2 py-1 text-xs"
                />
                <button
                  type="submit"
                  class="rounded-md bg-primary px-3 py-1.5 text-xs font-semibold text-primary-foreground hover:bg-primary-700"
                >
                  Submit for review
                </button>
              </form>

              <form
                :if={rule.status == "pending_fsq_review"}
                phx-submit="review_decision"
                class="flex flex-col items-end gap-2"
              >
                <input type="hidden" name="rule_id" value={rule.id} />
                <input
                  type="text"
                  name="actor"
                  placeholder="Your name (FSQ)"
                  required
                  class="w-40 rounded-md border border-input px-2 py-1 text-xs"
                />
                <textarea
                  name="comment"
                  placeholder="Comment (required to reject / request revision)"
                  class="w-56 rounded-md border border-input px-2 py-1 text-xs"
                  rows="2"
                ></textarea>
                <div class="flex gap-2">
                  <button
                    type="submit"
                    name="decision"
                    value="approve"
                    class="rounded-md bg-success-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-success-700"
                  >
                    Approve
                  </button>
                  <button
                    type="submit"
                    name="decision"
                    value="request_revision"
                    class="rounded-md bg-warning-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-warning-700"
                  >
                    Request revision
                  </button>
                  <button
                    type="submit"
                    name="decision"
                    value="reject"
                    class="rounded-md bg-danger-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-danger-700"
                  >
                    Reject
                  </button>
                </div>
              </form>

              <form
                :if={rule.status == "approved"}
                phx-submit="retire"
                class="flex items-center gap-2"
              >
                <input type="hidden" name="rule_id" value={rule.id} />
                <input
                  type="text"
                  name="actor"
                  placeholder="Your name"
                  required
                  class="w-28 rounded-md border border-input px-2 py-1 text-xs"
                />
                <button
                  type="submit"
                  class="rounded-md border border-danger-300 px-3 py-1.5 text-xs font-semibold text-danger-700 hover:bg-danger-50"
                >
                  Retire
                </button>
              </form>
            </div>
          </div>

          <div :if={MapSet.member?(@expanded, rule.id)} class="mt-4 border-t border-border pt-3">
            <h3 class="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
              Version history
            </h3>
            <ul class="mt-2 space-y-1">
              <li
                :for={version <- ThresholdRules.list_versions(rule)}
                class="flex items-center gap-2 text-xs"
              >
                <span class={[
                  "rounded-md px-1.5 py-0.5 font-semibold uppercase",
                  status_badge_class(version.status)
                ]}>
                  {status_label(version.status)}
                </span>
                <span class="text-card-foreground">v{version.version}</span>
                <span class="text-muted-foreground">updated {format_datetime(version.updated_at)}</span>
              </li>
            </ul>

            <h3 class="mt-3 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
              Audit trail
            </h3>
            <ul class="mt-2 space-y-1">
              <li
                :for={audit <- ThresholdRules.list_family_audits(rule)}
                class="text-xs text-card-foreground"
              >
                <span class="font-semibold">{audit.actor}</span>
                {audit.action} ({audit.from_status || "—"} → {audit.to_status})
                <span class="text-muted-foreground">on {format_datetime(audit.inserted_at)}</span>
                <span :if={audit.comment}>— "{audit.comment}"</span>
              </li>
            </ul>
          </div>
        </li>
      </ul>

      <.rule_form_modal
        :if={@live_action in [:new, :edit]}
        live_action={@live_action}
        rule={@rule}
        form={@form}
      />
    </Layouts.app>
    """
  end

  attr :live_action, :atom, required: true
  attr :rule, :any, required: true
  attr :form, :any, required: true

  defp rule_form_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div class="w-full max-w-xl rounded-lg bg-card p-6 shadow-lg">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-semibold text-card-foreground">
            {if @live_action == :new, do: "New threshold rule", else: "Edit threshold rule"}
          </h2>
          <.link
            navigate={~p"/rules"}
            class="text-sm text-muted-foreground hover:text-card-foreground"
          >Cancel</.link>
        </div>

        <p
          :if={@live_action == :edit and @rule.status == "approved"}
          class="mb-3 rounded-md bg-warning-100 px-3 py-2 text-xs text-warning-700"
        >
          This rule is approved and currently enforced. Saving creates a new draft
          version for FSQ review — the approved version keeps running until the
          new one is approved.
        </p>

        <.form id="rule-form" for={@form} phx-change="validate" phx-submit="save" class="space-y-3">
          <div>
            <label class="block text-xs font-semibold text-muted-foreground mb-1">Your name</label>
            <input
              type="text"
              name="actor"
              required
              class="w-full rounded-md border border-input px-2 py-1.5 text-sm"
            />
          </div>

          <.input field={@form[:commodity]} label="Commodity" placeholder="e.g. frozen_food" />
          <.input
            field={@form[:trigger_condition]}
            type="textarea"
            label="Trigger condition (human-readable, for FSQ review)"
          />

          <div class="grid grid-cols-2 gap-3">
            <.input
              field={@form[:comparator]}
              type="select"
              label="Comparator"
              prompt="Select..."
              options={[{"Above boundary", "above"}, {"Below boundary", "below"}]}
            />
            <.input
              field={@form[:severity]}
              type="select"
              label="Severity"
              prompt="Select..."
              options={[
                {"Critical", "critical"},
                {"High", "high"},
                {"Medium", "medium"},
                {"Low", "low"}
              ]}
            />
          </div>

          <div class="grid grid-cols-3 gap-3">
            <.input field={@form[:boundary_value]} type="number" label="Boundary value" step="any" />
            <.input field={@form[:hysteresis_gap]} type="number" label="Hysteresis gap" step="any" />
            <.input
              field={@form[:rate_of_change_threshold]}
              type="number"
              label="Rate/sec (optional)"
              step="any"
            />
          </div>

          <.input field={@form[:duration_window]} type="number" label="Duration window (seconds)" />
          <.input field={@form[:expected_outcome]} type="textarea" label="Expected outcome" />
          <.input field={@form[:recommended_action]} type="textarea" label="Recommended action" />
          <.input field={@form[:source_reference]} label="Source reference" />

          <div class="flex justify-end gap-2 pt-2">
            <.link
              navigate={~p"/rules"}
              class="rounded-md border border-border px-4 py-2 text-sm font-semibold text-card-foreground hover:bg-muted"
            >
              Cancel
            </.link>
            <button
              type="submit"
              class="rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground hover:bg-primary-700"
            >
              Save draft
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
