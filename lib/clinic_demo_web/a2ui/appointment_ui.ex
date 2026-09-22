defmodule ClinicDemoWeb.A2ui.AppointmentUI do
  @moduledoc """
  The schedule board: every appointment in one grid, booking in the form,
  and the visit lifecycle's transitions as row actions gated by status.

  Booking is the interesting write — it starts the visit process (triage
  runs inline before the row lands), which is why the form sits here rather
  than on a separate page.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Scheduling.Appointment
    surface_id "clinic_schedule"
    title "Schedule"
    record_label("appointment")
    spec_version "1.0"

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

      # Every transition is its own Ash action with a CurrentStatusIn guard;
      # visible_when mirrors the guard so the button never offers a refusal.
      row_actions [:check_in, :record_triage, :complete, :mark_no_show, :discharge, :cancel]
    end

    # The form that starts the whole visit process.
    component :form do
      fields [:patient_id, :clinician_id, :scheduled_at, :duration_minutes, :reason, :severity]
      create_action :book
    end

    action :check_in do
      visible_when status: :scheduled
    end

    action :record_triage do
      prompt_fields [:urgency]
      prompt_title "Record triage"
      visible_when status: [:scheduled, :checked_in]
    end

    action :complete do
      prompt_fields [:notes]
      prompt_title "Write up the consult"
      visible_when status: :checked_in
    end

    action :mark_no_show do
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
