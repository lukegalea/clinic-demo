defmodule ClinicDemoWeb.A2ui.EmergencyBoardUI do
  @moduledoc """
  The emergency board: appointments the triage table has routed as
  emergencies.

  Promoted from an agent-composed `AshA2ui.Dynamic` surface spec — the first
  surface in this app that was not hand-written. The agent's spec named five
  fields over Appointment; two verifier rounds rejected a shape error
  (`"type"` vs `"kind"`) and an unknown field (`chief_complaint`) before the
  spec resolved. Provenance recorded at promotion:

    spec fingerprint: sha256:91de344f3fb0fd6bbb6d001c071cfb115eed7d36499521497a63aea44a6f8c9f
    spec format:      1
    resource:         ClinicDemo.Scheduling.Appointment

  The hand-finishing every promotion gets: a stable surface_id, the
  emergencies-only preset the spec intended, and field labels.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Scheduling.Appointment
    surface_id "clinic_emergency_board"
    title "Emergency board"
    record_label("emergency")
    spec_version "1.0"

    query :default do
      sortable [:scheduled_at, :severity]
      filters [:triage_urgency, :status]
      default_sort severity: :desc
      page_size 25

      preset :emergencies do
        filter triage_urgency: :emergency
      end

      default_preset :emergencies
    end

    component :table do
      fields [:patient_label, :scheduled_at, :triage_urgency, :status, :reason]
      read_action :read
      query :default
    end

    field :patient_label do
      label "Patient"
    end
  end
end
