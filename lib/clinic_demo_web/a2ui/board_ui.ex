defmodule ClinicDemoWeb.A2ui.BoardUI do
  @moduledoc """
  The clinic board: the process as lanes, one card column per stage.

  A `display :board` table: the lanes are the values of the appointment's
  `board_lane` calculation (an atom with `one_of`), so the board's shape is
  declared next to the lane logic rather than seeded into a table. Each
  lane is an expanded table reading appointments whose `board_lane` equals
  that value, and a lane move IS a state transition: the same row actions
  as the schedule (check in, complete, discharge), each refreshing the
  `:board` template key — every lane — so a card landing in its new lane
  is the action's success feedback. There is no drag-and-drop by design:
  the resource's own actions keep the state machine's rules.

  Check in and no-show are `via`-delegated to
  `ClinicDemo.Visits.VisitFacade`: the click completes the visit's
  `CheckIn` work item through the engine and the token moves the
  appointment — the board never sets state around the process.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Scheduling.Appointment
    surface_id "clinic_board"
    title "Clinic board"
    record_label("appointment")
    spec_version "0.9.1"

    component :table, :board do
      display :board

      fields [
        :patient_label,
        :compliance_status,
        :acuity_fact,
        :triage_urgency,
        :clinician_label,
        :scheduled_at,
        :severity,
        :status,
        :discharged_at
      ]

      # The board is the process now: the `:board` read scopes to today's
      # visits and onward (see the action's description). The plain :read
      # would drag the finance seeds' six-month archive onto the lanes.
      read_action :board

      # The row badge is compliance: would the active bundle refuse this
      # visit's check-in? The acuity FACT leads the meta row — what the
      # judgment record admits about this patient, three-valued (the
      # admitted urgency / "ruled out" / "no fact") — before the visit's
      # own recorded triage answer.
      row_layout do
        title :patient_label
        badge :compliance_status

        badge_text(
          compliant: "Compliant",
          noncompliant: "Noncompliant",
          no_rules: "No rules",
          unknown: "Unknown"
        )

        meta [
          :acuity_fact,
          :triage_urgency,
          :clinician_label,
          :scheduled_at,
          :severity,
          :status,
          :discharged_at
        ]

        columns 2
      end

      # Every transition is its own Ash action, guarded by the resource's
      # state machine; visible_when mirrors the machine so a card only
      # offers the moves its state allows.
      row_actions [:check_in, :complete, :mark_no_show, :cancel, :discharge]

      # Source-less: the lanes are board_lane's `one_of` values, in the
      # order the clinic reads its day, headed in the clinic's words.
      sections do
        scope_by :board_lane
        values [:intake, :low, :medium, :high, :in_visit, :discharged, :closed]

        labels intake: "Booked",
               low: "Low — routine",
               medium: "Medium — soon",
               high: "High — urgent & emergency",
               in_visit: "In visit",
               discharged: "Discharged",
               closed: "Closed"
      end
    end

    # Via-delegated to the engine facade: the click completes the visit's
    # CheckIn work item and the token performs the transition.
    action :check_in do
      refreshes [:board]
      via {ClinicDemo.Visits.VisitFacade, :check_in_task, ["board"]}
      visible_when status: :scheduled
    end

    action :complete do
      refreshes [:board]
      prompt_fields [:notes]
      prompt_title "Write up the consult"
      visible_when status: :checked_in
    end

    action :mark_no_show do
      refreshes [:board]
      via {ClinicDemo.Visits.VisitFacade, :check_in_task, ["board"]}
      visible_when status: :scheduled
    end

    action :discharge do
      refreshes [:board]
      # Same guard as the schedule: :status stays :completed, so the
      # discharged_at nil-check is what makes the button leave the row and
      # the card show the outcome.
      visible_when status: :completed, discharged_at: nil
    end

    action :cancel do
      refreshes [:board]
      prompt_fields [:reason]
      prompt_title "Cancel appointment"
      visible_when status: [:scheduled, :checked_in]
    end

    field :patient_label do
      label "Patient"
    end

    field :clinician_label do
      label "Clinician"
    end

    field :scheduled_at do
      label "When"
    end

    field :severity do
      label "Severity (1–5)"
    end

    field :triage_urgency do
      label "Triage"
    end

    field :acuity_fact do
      label "Acuity (fact)"
    end

    field :compliance_status do
      label "Compliance"
    end

    field :discharged_at do
      label "Discharged"
    end
  end
end
