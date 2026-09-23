defmodule ClinicDemoWeb.A2ui.AppointmentUI do
  @moduledoc """
  The schedule board: every appointment in one grid, and the visit
  lifecycle's transitions as row actions gated by status.

  Booking does not live here — the intake screen owns the one booking form
  (with its patient picker and new-patient registration), keeping the
  clinic's flow to two screens: intake to book, this schedule and the
  board to work the visits.

  Check in and no-show are `via`-delegated to
  `ClinicDemo.Visits.VisitFacade`, so the click completes the visit's
  `CheckIn` work item through the engine and the token performs the
  transition — same path as the board and the worklist.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Scheduling.Appointment
    surface_id "clinic_schedule"
    title "Schedule"
    record_label("appointment")
    spec_version "0.9.1"

    query :default do
      search_fields [:reason, [:patient, :name], [:clinician, :full_name]]
      sortable [:scheduled_at, :status, :severity]
      filters [:status, :triage_urgency]
      range_filters [:scheduled_at]
      default_sort scheduled_at: :asc
      page_size 25
    end

    component :table do
      fields [
        :patient_label,
        :clinician_label,
        :scheduled_at,
        :ends_at,
        :reason,
        :severity,
        :status,
        :triage_urgency
      ]

      read_action :read
      query :default

      row_layout do
        title :patient_label
        badge :triage_urgency
        badge_text emergency: "Emergency", urgent: "Urgent", soon: "Soon", routine: "Routine"
        meta [:clinician_label, :scheduled_at, :ends_at, :reason, :severity, :status]
        columns 3
      end

      # Every transition is its own Ash action, guarded by the resource's
      # state machine; visible_when mirrors the machine so the button
      # never offers a refusal.
      row_actions [:check_in, :complete, :mark_no_show, :discharge, :cancel]
    end

    # Via-delegated to the engine facade: the click completes the visit's
    # CheckIn work item and the token performs the transition.
    action :check_in do
      via {ClinicDemo.Visits.VisitFacade, :check_in_task, ["schedule"]}
      visible_when status: :scheduled
    end

    action :complete do
      prompt_fields [:notes]
      prompt_title "Write up the consult"
      visible_when status: :checked_in
    end

    action :mark_no_show do
      via {ClinicDemo.Visits.VisitFacade, :check_in_task, ["schedule"]}
      visible_when status: :scheduled
    end

    action :discharge do
      visible_when status: :completed
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

    field :ends_at do
      label "Until"
    end

    field :severity do
      label "Severity (1–5)"
    end

    field :triage_urgency do
      label "Triage"
    end
  end
end
