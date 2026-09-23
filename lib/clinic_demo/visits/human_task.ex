defmodule ClinicDemo.Visits.HumanTask do
  @moduledoc """
  A work item waiting on a person: the front desk checking an animal in, the vet
  seeing it, the lab reporting back. Each one is a token that has stopped.
  """

  use AshBpmn.Resources.HumanTask,
    domain: ClinicDemo.Visits,
    repo: ClinicDemo.Repo,
    instance: ClinicDemo.Visits.Instance,
    token: ClinicDemo.Visits.Token,
    table: "bpmn_human_tasks"

  relationships do
    # Candidacy rows are materialised when the task is created. The worklist
    # surfaces filter through them — "what may *this* clinician act on?".
    has_many :candidates, ClinicDemo.Visits.TaskCandidate do
      destination_attribute :task_id
      public? true
    end
  end

  actions do
    # The worklist surface completes tasks through the engine facade so the
    # token advances with the outcome; a plain update would leave the visit
    # standing at the same node. ActionHandler invokes this as a generic row
    # action, injecting the row's id as :record_id; the engine enforces
    # candidacy itself, so the policy only asks that someone is acting.
    action :a2ui_complete, :struct do
      description "Complete the task through the engine, routing the token onwards."

      argument :record_id, :uuid do
        allow_nil? false
        description "The task being completed (injected by the surface)."
      end

      argument :outcome, :atom do
        allow_nil? false
        constraints one_of: [:arrived, :no_show, :written_up, :labs_pending, :results_in]
        description "The task's outcome; routes the token onwards."
      end

      argument :comment, :string do
        description "Optional note recorded with the completion."
      end

      run fn input, %{actor: actor} ->
        # Ash.get!/3 is (resource, id, opts) — the record id is the SECOND
        # argument. Piping the id in made it the resource, which raised
        # ArgumentError inside the LiveView process and took the surface's
        # GenServer with it (the client saw a "Surface already exists"
        # remount instead of an error).
        ClinicDemo.Visits.HumanTask
        |> Ash.get!(input.arguments.record_id, authorize?: false)
        |> AshBpmn.complete_task(
          outcome: input.arguments.outcome,
          comment: input.arguments.comment,
          actor: actor
        )
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:a2ui_complete) do
      description "Anyone acting may try; the engine refuses non-candidates."
      authorize_if actor_present()
    end
  end
end
