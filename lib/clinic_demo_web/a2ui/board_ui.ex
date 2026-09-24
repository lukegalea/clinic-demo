defmodule ClinicDemoWeb.A2ui.BoardUI do
  @moduledoc """
  The clinic board: the process as lanes, one card column per stage.

  A sectioned table — the lanes are seeded `BoardLane` rows, each expanded
  table reads appointments whose `board_lane` calculation equals the lane
  key, and a lane move IS a state transition: the same row actions as the
  schedule (check in, complete, discharge), no refreshes clause — every
  action refreshes every lane, so a card landing in its new lane is the
  action's success feedback.

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
      fields [
        :patient_label,
        :compliance_status,
        :triage_urgency,
        :clinician_label,
        :scheduled_at,
        :severity,
        :status,
        :discharged_at
      ]

      read_action :read

      # The row badge is compliance: would the active bundle refuse this
      # visit's check-in? Triage stays visible as the meta row's lead value —
      # the lane colors live on the day view's dots either way.
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

      sections do
        source ClinicDemo.Scheduling.BoardLane
        scope_by :board_lane
        label :label
        value :lane_key
        sort :position
        limit 10
      end
    end

    # Via-delegated to the engine facade: the click completes the visit's
    # CheckIn work item and the token performs the transition.
    action :check_in do
      via {ClinicDemo.Visits.VisitFacade, :check_in_task, ["board"]}
      visible_when status: :scheduled
    end

    action :complete do
      prompt_fields [:notes]
      prompt_title "Write up the consult"
      visible_when status: :checked_in
    end

    action :mark_no_show do
      via {ClinicDemo.Visits.VisitFacade, :check_in_task, ["board"]}
      visible_when status: :scheduled
    end

    action :discharge do
      # Same guard as the schedule: :status stays :completed, so the
      # discharged_at nil-check is what makes the button leave the row and
      # the card show the outcome.
      visible_when status: :completed, discharged_at: nil
    end

    action :cancel do
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

    field :compliance_status do
      label "Compliance"
    end

    field :discharged_at do
      label "Discharged"
    end
  end
end
