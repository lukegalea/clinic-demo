defmodule ClinicDemoWeb.A2ui.WorklistUI do
  @moduledoc """
  The worklist: the acting clinician's human tasks as a board, Open and
  Claimed, moved through the engine so the visit's token advances with
  the outcome.

  The lanes are the values of the task's `status` (an atom with `one_of`),
  narrowed to the two a person acts on. The read is `:worklist`, the
  candidacy read: open tasks the actor is a candidate for and claimed tasks
  the actor holds, so with nobody acting the board is empty.

  Each move is a generic action on `ClinicDemo.Visits.HumanTask`, run as the
  actor through `ClinicDemo.Visits.TaskDesk`:

    * **Claim task** (open cards): the engine checks candidacy.
    * **Complete task** (open or claimed): a prompt for the outcome and an
      optional comment. Completing an open task claims it on the way.
    * **Delegate task** (claimed cards): a prompt naming the colleague, by
      full name or licence number. Only the holder may hand it on.

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

    # Soonest due first, 25 cards a lane. The query is also what makes the
    # initial render read as the actor: ash_a2ui a3c1763 builds a query-less
    # table's read without the actor and hands it only to Ash.read!, so the
    # :worklist preparation would see nobody acting. The query path builds
    # the read with the actor. It declares no search, presets or filters, so
    # the lanes show no query controls.
    query :default do
      sortable [:due_at]
      default_sort due_at: :asc
      page_size 25
    end

    component :table, :board do
      display :board
      fields [:name, :node_id, :status, :due_at]
      read_action :worklist
      query :default

      row_layout do
        title :name
        badge :status
        meta [:node_id, :due_at]
        columns 2
      end

      row_actions [:claim_task, :complete_task, :delegate_task]

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

    action :complete_task do
      prompt_fields [:outcome, :comment]
      prompt_title "Complete task"
      visible_when status: [:open, :claimed]
      refreshes [:board]
    end

    action :delegate_task do
      prompt_fields [:to]
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
  end
end
