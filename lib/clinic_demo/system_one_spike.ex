defmodule ClinicDemo.SystemOneSpike do
  @moduledoc """
  Spike-0: three typed questions asked of an Ollaya-served decision model.

  Each action is `run evaluate(...)` from `ash_ai`. The action's return type is
  the question's answer type, so `ash_ai` derives the question from it and casts
  the model's answer back into it. Nothing here writes: there is no data layer,
  no ledger, and no change to any clinic rule.

    * `notes_follow_up` — a noul (probability of yes) over free-text `notes`.
    * `presenting_urgency` — a choice over the options of
      `Appointment.triage_urgency`, plus `:insufficient_information`, because
      abstaining is a result.
    * `both` — the two questions in one request, to measure batching.

  Every action returns `AshAi.Actions.Result`, so the answer arrives with the
  model id the server reported and its token usage.

  The model is chosen per call through the action input's context. See
  `ClinicDemo.SystemOneSpike.Models`:

      ClinicDemo.SystemOneSpike
      |> Ash.ActionInput.for_action(:notes_follow_up, %{notes: "..."},
        context: %{system_one_spike: %{spec: :laya, transport: :live}}
      )
      |> Ash.run_action()
  """

  use Ash.Resource, domain: ClinicDemo.Spikes

  import AshAi.Actions, only: [evaluate: 1]

  alias ClinicDemo.SystemOneSpike.Models

  @urgency_options Ash.Resource.Info.attribute(ClinicDemo.Scheduling.Appointment, :triage_urgency).constraints[
                     :one_of
                   ] ++ [:insufficient_information]

  @doc "The presenting-urgency options, in the order they are offered."
  def urgency_options, do: @urgency_options

  @follow_up_question """
  Do `notes` record a concrete follow-up plan for this patient: a recheck, a medication \
  course with an end, or a referral?\
  """

  @follow_up_criteria [
    true: "A specific follow-up for this patient is planned.",
    false: "No follow-up, follow-up explicitly declined, or only general advice."
  ]

  @urgency_question """
  From `reason`, the owner's description when booking, together with `species` and \
  `age_band`, how urgently does this animal need to be seen?\
  """

  @urgency_descriptions [
    emergency:
      "Life-threatening now: collapse, seizure, heavy bleeding, toxin ingestion, cannot breathe or urinate.",
    urgent:
      "Needs seeing today or tomorrow: significant pain, repeated vomiting, not eating for days, eye injury.",
    soon:
      "Should be seen within the week: mild or chronic signs that are not getting rapidly worse.",
    routine: "Preventive or elective: vaccination, health check, nail trim, planned dental.",
    insufficient_information: "The description does not say enough to judge urgency."
  ]

  @urgency_constraints [
    of: :atom,
    constraints: [one_of: @urgency_options],
    descriptions: @urgency_descriptions
  ]

  actions do
    action :notes_follow_up, AshAi.Actions.Result do
      description @follow_up_question

      constraints of: AshAi.Evaluate.Noul, constraints: [criteria: @follow_up_criteria]

      argument :notes, :string, allow_nil?: false, constraints: [allow_empty?: false]

      run evaluate(&Models.for_input/2)
    end

    action :presenting_urgency, AshAi.Actions.Result do
      description @urgency_question

      constraints of: AshAi.Evaluate.Choice, constraints: @urgency_constraints

      argument :reason, :string, allow_nil?: false
      argument :species, :string, allow_nil?: false
      argument :age_band, :string, allow_nil?: false

      run evaluate(&Models.for_input/2)
    end

    action :both, AshAi.Actions.Result do
      description "Both spike questions in one request."

      constraints of: AshAi.Evaluate.Judgments,
                  constraints: [
                    fields: [
                      follow_up: [
                        type: AshAi.Evaluate.Noul,
                        constraints: [criteria: @follow_up_criteria],
                        description: @follow_up_question
                      ],
                      urgency: [
                        type: AshAi.Evaluate.Choice,
                        constraints: @urgency_constraints,
                        description: @urgency_question
                      ]
                    ]
                  ]

      argument :notes, :string, allow_nil?: false, constraints: [allow_empty?: false]
      argument :reason, :string, allow_nil?: false
      argument :species, :string, allow_nil?: false
      argument :age_band, :string, allow_nil?: false

      run evaluate(&Models.for_input/2)
    end
  end
end
