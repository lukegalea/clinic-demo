defmodule ClinicDemo.Visits.HumanTask do
  @moduledoc """
  A work item waiting on a person: the front desk checking an animal in, the vet
  seeing it, the lab reporting back. Each one is a token that has stopped.

  The engine's generated resource carries the `:candidates` rows and the
  `:outcomes` the task's BPMN step declares. The worklist reads through
  this module's `:worklist`, the engine's candidacy read narrowed with a
  filter so that counts narrow too. This module adds the board's
  three moves (claim, complete, delegate) as generic actions, run as the
  acting clinician; completion comes once per step, so each prompt offers
  only its step's outcomes.
  """

  use AshBpmn.Resources.HumanTask,
    domain: ClinicDemo.Visits,
    repo: ClinicDemo.Repo,
    instance: ClinicDemo.Visits.Instance,
    token: ClinicDemo.Visits.Token,
    task_candidate: ClinicDemo.Visits.TaskCandidate,
    table: "bpmn_human_tasks"

  alias ClinicDemo.Visits.TaskDesk

  postgres do
    references do
      # The holder, for reading. The engine writes `assignee_id` (and may in
      # principle name a team there), so the column carries no foreign key.
      reference :assignee, ignore?: true
    end
  end

  relationships do
    # Every assignee in this clinic is a clinician: candidates are clinicians,
    # and a claim or a delegation names one. The relationship is also what
    # the Delegate prompt's picker lists its options from.
    belongs_to :assignee, ClinicDemo.Scheduling.Clinician do
      source_attribute :assignee_id
      define_attribute? false
      public? true
    end
  end

  calculations do
    calculate :outcome_choices,
              :string,
              ClinicDemo.Visits.Calculations.OutcomeChoices do
      public? true
      description "The outcomes the task's step declares, as a phrase: \"Arrived or No show\"."
    end
  end

  actions do
    # The worklist board's read: what the acting clinician can act on. The
    # engine's `:awaiting_actor` answers the same question, but narrows in a
    # before_action hook that `Ash.count/2` skips, so the board's lane
    # counts would count everyone's tasks (see the preparation).
    read :worklist do
      description "Open tasks the actor is a candidate for, and claimed tasks the actor holds."
      prepare ClinicDemo.Visits.Preparations.Worklist
    end

    # The board's three moves, each a generic action the surface invokes
    # with the card's id as :record_id. They run through
    # ClinicDemo.Visits.TaskDesk, which reads the task as the actor and calls
    # the engine; the engine decides who may claim, complete or delegate.
    action :claim_task, :struct do
      description "Claim an open task for the acting clinician."

      argument :record_id, :uuid do
        allow_nil? false
        description "The task being claimed (injected by the surface)."
      end

      run fn input, %{actor: actor} ->
        TaskDesk.claim(input.arguments.record_id, actor)
      end
    end

    action :complete_task, :struct do
      description "Complete the task through the engine, routing the token onwards."

      argument :record_id, :uuid do
        allow_nil? false
        description "The task being completed (injected by the surface)."
      end

      # Every outcome the visit process declares. Which of them a given task
      # takes is its step's `:outcomes`, which TaskDesk checks.
      argument :outcome, :atom do
        allow_nil? false
        constraints one_of: [:arrived, :no_show, :written_up, :labs_pending, :results_in]
        description "The task's outcome, one its step declares; routes the token onwards."
      end

      argument :comment, :string do
        description "Optional note recorded with the completion."
      end

      run ClinicDemo.Visits.HumanTask.Complete
    end

    # The worklist's Complete button, once per step of the visit process, so
    # its prompt offers exactly the outcomes that step declares in
    # `<ash:outcomes>`. The board shows each on its own step's cards; the
    # test suite checks each list against the compiled diagram.
    action :complete_check_in, :struct do
      description "Complete a CheckIn task: the animal arrived, or did not."

      argument :record_id, :uuid do
        allow_nil? false
        description "The task being completed (injected by the surface)."
      end

      argument :outcome, :atom do
        allow_nil? false
        constraints one_of: [:arrived, :no_show]
        description "Whether the animal arrived."
      end

      argument :comment, :string do
        description "Optional note recorded with the completion."
      end

      run ClinicDemo.Visits.HumanTask.Complete
    end

    action :complete_consult, :struct do
      description "Complete a Consult task: written up, or waiting on labs."

      argument :record_id, :uuid do
        allow_nil? false
        description "The task being completed (injected by the surface)."
      end

      argument :outcome, :atom do
        allow_nil? false
        constraints one_of: [:written_up, :labs_pending]
        description "Whether the visit is written up or waits on lab results."
      end

      argument :comment, :string do
        description "Optional note recorded with the completion."
      end

      run ClinicDemo.Visits.HumanTask.Complete
    end

    action :complete_lab_results, :struct do
      description "Complete an AwaitLabResults task: the results are in."

      argument :record_id, :uuid do
        allow_nil? false
        description "The task being completed (injected by the surface)."
      end

      argument :outcome, :atom do
        allow_nil? false
        constraints one_of: [:results_in]
        description "The results are in."
      end

      argument :comment, :string do
        description "Optional note recorded with the completion."
      end

      run ClinicDemo.Visits.HumanTask.Complete
    end

    action :delegate_task, :struct do
      description "Hand a claimed task to another clinician who is one of its candidates."

      argument :record_id, :uuid do
        allow_nil? false
        description "The task being delegated (injected by the surface)."
      end

      argument :delegate_id, :uuid do
        allow_nil? false
        description "The clinician taking the task."
      end

      run fn input, %{actor: actor} ->
        TaskDesk.delegate(input.arguments.record_id, input.arguments.delegate_id, actor)
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([
             :claim_task,
             :complete_task,
             :complete_check_in,
             :complete_consult,
             :complete_lab_results,
             :delegate_task
           ]) do
      description "Anyone acting may try; the engine refuses whoever the task is not for."
      authorize_if actor_present()
    end
  end
end
