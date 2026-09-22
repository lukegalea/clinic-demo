defmodule ClinicDemo.Decisions.Evaluation do
  @moduledoc """
  One append-only row per invoked decision: the inputs, the outputs, the version
  that decided and how long it took.

  This is the evidence trail. `AshDecisions.Evaluator` writes it through the
  package's own policy bypass, which is why the write policy below can be as
  strict as it is without the engine tripping over it.
  """

  use AshDecisions.Resources.Evaluation,
    domain: ClinicDemo.Decisions,
    repo: ClinicDemo.Repo,
    definition: ClinicDemo.Decisions.Definition,
    table: "dmn_evaluations"

  calculations do
    # The evidence trail's "which visit was this?" answer: the patient and
    # the reason, resolved from the correlation_id (the visit instance's id)
    # through to the appointment it was about. Cross-domain by nature —
    # Evaluation to Instance to Appointment to Patient.
    calculate :visit_label, :string, ClinicDemo.Decisions.Calculations.VisitLabel do
      public? true
      load [:correlation_id]
    end
  end

  policies do
    policy action_type(:read) do
      description "The audit trail is readable; it is the reason it exists."
      authorize_if always()
    end
  end
end
