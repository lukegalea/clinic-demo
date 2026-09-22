defmodule ClinicDemoWeb.A2ui.BoardUI do
  @moduledoc """
  The clinic board: the process as lanes, one card column per stage.

  A sectioned table — the lanes are seeded `BoardLane` rows, each expanded
  table reads appointments whose `board_lane` calculation equals the lane
  key, and a lane move IS a state transition: the same row actions as the
  schedule (check in, record triage, complete, discharge), no refreshes
  clause — every action refreshes every lane, so a card landing in its new
  lane is the action's success feedback.
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
        :triage_urgency,
        :clinician_label,
        :scheduled_at,
        :severity,
        :status
      ]

      read_action :read

      row_layout do
        title :patient_label
        badge :triage_urgency
        badge_text emergency: "Emergency", urgent: "Urgent", soon: "Soon", routine: "Routine"
        meta [:clinician_label, :scheduled_at, :severity, :status]
        columns 2
      end

      # Every transition is its own Ash action with a CurrentStatusIn guard;
      # visible_when mirrors the guard so a card only offers the moves its
      # state allows.
      row_actions [:check_in, :record_triage, :complete, :mark_no_show, :cancel, :discharge]

      sections do
        source ClinicDemo.Scheduling.BoardLane
        scope_by :board_lane
        label :label
        value :lane_key
        sort :position
        limit 10
      end
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

    field :severity do
      label "Severity (1–5)"
    end

    field :triage_urgency do
      label "Triage"
    end
  end
end
