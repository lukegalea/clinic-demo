defmodule ClinicDemo.Compliance.AppointmentRules do
  @moduledoc """
  The operator-edited rule bundle guarding the appointment state machine.

  Written in the `AshRules` DSL so the clinic's compliance rules live as data:
  the same module compiles to a content-hashed bundle that is drafted,
  approved and activated through the compliance control plane, and the guard
  on each appointment transition evaluates the *activated* bundle — never this
  module directly. Editing this file changes nothing until a new revision has
  been through that lifecycle, which is the point: the rules in force are
  rows, not code.

  Facts are precomputed by the guard (see
  `ClinicDemo.Scheduling.Changes.ComplianceGuard`): the rules probe plain
  triples like `{:appointment, :patient_weight_recorded, true}` so the rule
  vocabulary stays about clinic policy, not about how appointments are stored.
  """

  use AshRules

  combining(:deny_overrides)

  fact_schema do
    fact(:transition_to, :atom,
      one_of: [:checked_in, :completed, :cancelled, :no_show],
      description: "The state-machine transition being attempted"
    )

    fact(:patient_weight_recorded, :boolean,
      description: "Whether the patient has a weight on record"
    )

    fact(:has_triage_urgency, :boolean,
      description: "Whether the triage decision has answered for this appointment"
    )

    fact(:has_notes, :boolean, description: "Whether consult notes are present")
  end

  rule "check-in requires a recorded weight",
    id: "appt.checkin_requires_weight",
    severity: :high do
    when_requires(has(:appointment, :transition_to, :checked_in))
    fails_when(neg(:appointment, :patient_weight_recorded, true))
    outcome(:noncompliant, gap: "record the patient's weight before check-in")
  end

  rule "completion requires triage urgency",
    id: "appt.complete_requires_triage",
    severity: :high do
    when_requires(has(:appointment, :transition_to, :completed))
    fails_when(neg(:appointment, :has_triage_urgency, true))
    outcome(:noncompliant, gap: "triage urgency missing")
  end

  rule "completion requires notes",
    id: "appt.complete_requires_notes",
    severity: :medium do
    when_requires(has(:appointment, :transition_to, :completed))
    fails_when(neg(:appointment, :has_notes, true))
    outcome(:noncompliant, gap: "consult notes required")
  end
end
