defmodule ClinicDemoWeb.A2ui.ClinicianUI do
  @moduledoc """
  Bookable staff. License number is required for veterinarians only — the
  create action enforces it, and the form inherits that too.

  Master/detail, the same shape as `PatientUI`: a row's select button picks
  the clinician into the `:clinician` context and the appointments table
  below reads their visits from `Appointment` (a related table). The pick
  rides the URL (`?ctx[clinician]=<id>`), where the schedule's clinician
  links land.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Scheduling.Clinician
    surface_id "clinic_clinicians"
    title "Clinicians"
    record_label("clinician")
    spec_version "0.9.1"

    context :clinician do
      resource ClinicDemo.Scheduling.Clinician
      option_label :full_name
      picker false
    end

    query :default do
      search_fields [:full_name, :license_number]
      sortable [:full_name]
      filters [:role, :active]
      default_sort full_name: :asc
    end

    # Named: two tables on this surface, and the name is the heading.
    component :table, :clinicians do
      fields [:full_name, :role, :license_number, :active, :upcoming_appointment_count]
      read_action :read
      query :default
      row_actions [:retire]
      select_context :clinician
    end

    # Read-only (a related table); visits are worked on the schedule.
    component :table, :appointments do
      resource ClinicDemo.Scheduling.Appointment
      fields [:scheduled_at, :patient_label, :reason, :status, :triage_urgency]
      read_action :read
      query :appointments
      context_filter clinician_id: :clinician
      require_context [:clinician]
    end

    # Checked against Appointment, the related table's resource.
    query :appointments do
      filters [:status]
      sortable [:scheduled_at]
      default_sort scheduled_at: :desc
      page_size 10
    end

    component :form do
      fields [:full_name, :role, :license_number]
      create_action :create
    end

    action :retire do
      visible_when active: true
    end

    # The appointments table's columns (Appointment fields).
    field :scheduled_at do
      label "When"
    end

    field :patient_label do
      label "Patient"
    end

    field :triage_urgency do
      label "Triage"
    end
  end
end
