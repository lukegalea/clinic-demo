defmodule ClinicDemoWeb.A2ui.IntakeUI do
  @moduledoc """
  Intake — screen one of the clinic's two-screen flow.

  Screen one (here): book the visit in ONE form. An existing patient is
  picked from the searchable patient picker; a patient who has never been
  in is registered right there, in the form's new-patient section, whose
  fields ride `Patient.register` and its validations. Exactly one of the
  two is required — the `:book` action refuses both and neither. Screen
  two: the board (and the schedule), where the booked visit is worked —
  check in through the engine, write it up, discharge.

  The recent-appointments table under the form is the receptionist's
  confirmation: the row lands with its triage urgency already decided,
  because booking is what starts the visit process.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Scheduling.Appointment
    surface_id "clinic_intake"
    title "Intake"
    record_label("appointment")
    spec_version "0.9.1"

    query :default do
      search_fields [:reason, [:patient, :name]]
      sortable [:scheduled_at]
      default_sort scheduled_at: :desc
      page_size 8
    end

    # The one booking form. The patient picker and the new-patient section
    # are the two modes of naming the patient; the :book action's
    # ExactlyOneOf validation keeps the form honest about picking one.
    component :form do
      fields [:patient_id, :clinician_id, :scheduled_at, :duration_minutes, :reason, :severity]

      create_action :book

      nested_form :patient do
        label "New patient — fill in only when they have never been in"
        fields [
          :name,
          :species,
          :breed,
          :date_of_birth,
          :weight_kg,
          :microchip_number,
          :owner_email
        ]
      end
    end

    component :table, :recent do
      fields [:patient_label, :reason, :scheduled_at, :status, :triage_urgency]
      read_action :read
      query :default

      row_layout do
        title :patient_label
        badge :triage_urgency
        badge_text emergency: "Emergency", urgent: "Urgent", soon: "Soon", routine: "Routine"
        meta [:reason, :scheduled_at, :status]
        columns 3
      end
    end

    field :patient_id do
      label "Patient"
      option_label :name
      option_search [:name]
    end

    field :clinician_id do
      label "Clinician"

      # The select's options label by :full_name — Clinician's identifying
      # attribute is not in the default label ladder, so without this the
      # picker shows bare UUIDs.
      option_label :full_name
    end

    field :scheduled_at do
      label "When"
    end

    field :duration_minutes do
      label "Length (minutes)"
    end

    field :severity do
      label "Severity (1–5)"
    end

    field :patient_label do
      label "Patient"
    end

    field :triage_urgency do
      label "Triage"
    end
  end
end
