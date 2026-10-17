defmodule ClinicDemoWeb.A2ui.WorklistUI do
  @moduledoc """
  The worklist: the acting clinician's human tasks as a board, Open and
  Claimed, moved through the engine so the visit's token advances with
  the outcome.

  The lanes are the values of the task's `status` (an atom with `one_of`),
  narrowed to the two a person acts on. The read is `:worklist`, the
  candidacy read: open tasks the actor is a candidate for and claimed tasks
  the actor holds, so with nobody acting the board is empty. It narrows with
  a filter, so the lane counts and the pager total are the actor's too.

  Each move is a generic action on `ClinicDemo.Visits.HumanTask`, run as the
  actor through `ClinicDemo.Visits.TaskDesk`; the engine decides who may
  make it:

    * **Claim task** (open cards): a candidate takes the task.
    * **Complete task** (open or claimed): a prompt picking the outcome and
      an optional comment. There is one action per step (`:complete_check_in`,
      `:complete_consult`, `:complete_lab_results`), each visible on its own
      step's cards, so the picker offers only what that step declares; the
      card shows the same list, and TaskDesk refuses any other. Completing
      an open task claims it on the way.
    * **Delegate task** (claimed cards): a prompt picking the colleague from
      the clinicians. Only the holder may hand it on, and only to another of
      the task's candidates.

  Every move refreshes the `:board` template key, so the card changing
  lane, or leaving the board, is the success feedback.

  This surface replaces the `/operator/tasks` page that wrapped
  `AshBpmn.Web.TaskListLive`. That page read every task with the engine's
  actor and passed no actor on claim, complete or delegate.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Visits.HumanTask
    surface_id "clinic_worklist"
    title "Worklist"
    record_label("task")
    spec_version "0.9.1"

    # Soonest due first, 25 cards a lane. It declares no search, presets or
    # filters, so the lanes show no query controls.
    query :default do
      sortable [:due_at]
      default_sort due_at: :asc
      page_size 25
    end

    component :table, :board do
      display :board
      fields [:name, :node_id, :status, :due_at, :outcome_choices]
      read_action :worklist
      query :default

      row_layout do
        title :name
        badge :status
        meta [:node_id, :due_at, :outcome_choices]
        columns 2
      end

      row_actions [
        :claim_task,
        :complete_check_in,
        :complete_consult,
        :complete_lab_results,
        :delegate_task
      ]

      sections do
        scope_by :status
        values [:open, :claimed]
        labels open: "Open", claimed: "Claimed"
      end
    end

    action :claim_task do
      visible_when status: :open
      refreshes [:board]
    end

    # One Complete per step, each shown only on its own step's cards, so the
    # outcome picker lists what that step declares.
    action :complete_check_in do
      label "Complete task"
      prompt_fields [:outcome, :comment]
      prompt_title "Complete task"
      visible_when status: [:open, :claimed], node_id: "CheckIn"
      refreshes [:board]
    end

    action :complete_consult do
      label "Complete task"
      prompt_fields [:outcome, :comment]
      prompt_title "Complete task"
      visible_when status: [:open, :claimed], node_id: "Consult"
      refreshes [:board]
    end

    action :complete_lab_results do
      label "Complete task"
      prompt_fields [:outcome, :comment]
      prompt_title "Complete task"
      visible_when status: [:open, :claimed], node_id: "AwaitLabResults"
      refreshes [:board]
    end

    action :delegate_task do
      prompt_fields [:delegate_id]
      prompt_title "Delegate task"
      visible_when status: :claimed
      refreshes [:board]
    end

    field :node_id do
      label "Step"
    end

    field :due_at do
      label "Due"
    end

    field :outcome_choices do
      label "Outcomes"
    end

    field :delegate_id do
      label "Colleague"
      relationship :assignee
      option_label :full_name
    end
  end
end
