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
    # read filters through them — "what may *this* clinician act on?".
    has_many :candidates, ClinicDemo.Visits.TaskCandidate do
      destination_attribute :task_id
      public? true
    end
  end

  actions do
    # The worklist board's read: what the acting clinician can act on. Open
    # tasks they are a candidate for and claimed tasks they hold; nobody
    # acting reads nothing (see the preparation for why it is not a filter).
    read :worklist do
      description "Open tasks the actor is a candidate for, and claimed tasks the actor holds."
      prepare ClinicDemo.Visits.Preparations.Worklist
    end

    # The board's three moves, each a generic action the surface invokes
    # with the card's id as :record_id. They run through
    # ClinicDemo.Visits.TaskDesk, which makes them as the actor and checks
    # what the engine does not: who may complete or delegate which task.
    action :claim_task, :struct do
      description "Claim an open task for the acting clinician."

      argument :record_id, :uuid do
        allow_nil? false
        description "The task being claimed (injected by the surface)."
      end

      run fn input, %{actor: actor} ->
        ClinicDemo.Visits.TaskDesk.claim(input.arguments.record_id, actor)
      end
    end

    action :complete_task, :struct do
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
        ClinicDemo.Visits.TaskDesk.complete(
          input.arguments.record_id,
          input.arguments.outcome,
          input.arguments.comment,
          actor
        )
      end
    end

    action :delegate_task, :struct do
      description "Hand a claimed task to another active clinician."

      argument :record_id, :uuid do
        allow_nil? false
        description "The task being delegated (injected by the surface)."
      end

      argument :to, :string do
        allow_nil? false
        description "The colleague taking the task: full name or licence number."
      end

      run fn input, %{actor: actor} ->
        ClinicDemo.Visits.TaskDesk.delegate(input.arguments.record_id, input.arguments.to, actor)
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:claim_task, :complete_task, :delegate_task]) do
      description "Anyone acting may try; TaskDesk refuses whoever the task is not for."
      authorize_if actor_present()
    end
  end
end
