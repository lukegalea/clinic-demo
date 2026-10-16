defmodule ClinicDemoWeb.A2ui.PatientUI do
  @moduledoc """
  Registered animals. The form is the register action — the email-format and
  not-yet-born validations live on the action, so the form inherits them.

  Master/detail: each row's select button picks the patient into the
  `:patient` context, and the appointments table below reads that
  patient's visits from `Appointment` itself (a related table, scoped by
  `context_filter`, read under Appointment's own policies). With no
  patient picked the appointments table reads nothing. `PatientsLive`
  keeps the pick in the URL (`?ctx[patient]=<id>`), which is also where
  the schedule's patient links land.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Scheduling.Patient
    surface_id "clinic_patients"
    title "Patients"
    record_label("patient")
    spec_version "0.9.1"

    # Selected only from a row's select button (or a ?ctx[patient] deep
    # link), never from a picker of its own: the table above is the picker.
    context :patient do
      resource ClinicDemo.Scheduling.Patient
      option_label :name
      picker false
    end

    query :default do
      search_fields [:name, :breed, :owner_email]
      sortable [:name]
      filters [:species]
      default_sort name: :asc
    end

    # Named because the surface has two tables: the name is the section
    # heading and the empty-state noun ("No Patients records yet.").
    component :table, :patients do
      fields [
        :name,
        :species,
        :breed,
        :date_of_birth,
        :weight_kg,
        :owner_email,
        :appointment_count
      ]

      read_action :read
      query :default
      row_actions [:record_weight]
      select_context :patient
    end

    # Read-only by construction (the verifier refuses row actions on a
    # related table); the visit lifecycle is worked on the schedule.
    component :table, :appointments do
      resource ClinicDemo.Scheduling.Appointment
      fields [:scheduled_at, :clinician_label, :reason, :status, :triage_urgency]
      read_action :read
      query :appointments
      context_filter patient_id: :patient
      require_context [:patient]
    end

    component :form do
      fields [
        :name,
        :species,
        :breed,
        :date_of_birth,
        :weight_kg,
        :microchip_number,
        :owner_email
      ]

      create_action :register
    end

    # Checked against Appointment, the related table's resource.
    query :appointments do
      filters [:status]
      sortable [:scheduled_at]
      default_sort scheduled_at: :desc
      page_size 10
    end

    action :record_weight do
      prompt_fields [:weight_kg]
      prompt_title "Record weight"
    end

    field :date_of_birth do
      label "Born"
      format :date
    end

    field :owner_email do
      label "Owner"
    end

    # The appointments table's columns (Appointment fields).
    field :scheduled_at do
      label "When"
    end

    field :clinician_label do
      label "Clinician"
    end

    field :triage_urgency do
      label "Triage"
    end
  end
end
