defmodule ClinicDemo.Planning.Candidate do
  @moduledoc """
  One candidate roster a run proposed: `AshPlanning.Fragment.Candidate` on the
  clinic's base, in table `planning_candidates`. A proposal, never an
  operational fact: nothing reads this table to decide anything about the
  schedule, so an unapplied candidate is inert.

  Who may do what:

    * `propose`, `record_check`, `mark_stale` and `supersede` are
      **machinery-only**: the planner writes them.
    * `approve` and `apply` are **four-eyes**: they are refused unless the clinic
      manager AND the head vet (two different clinicians) have each signed the
      candidate off, and the actor is one of them
      (`ClinicDemo.Planning.Checks.FourEyesSignedOff`). The roster approval
      process (`ClinicDemo.Planning.FourEyes`) is what calls them.
    * `reject` is any leadership clinician: either approver may turn a candidate
      down.

  `apply` is where the schedule changes: `ClinicDemo.Planning.Changes.ApplyCandidate`
  rechecks every input the plan read, writes the `Shift` and `Assignment` rows in
  the action's own transaction as the approving person, and on drift refuses and
  leaves the candidate `:rejected` and `:stale`.
  """

  use Ash.Resource,
    domain: ClinicDemo.Planning,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    fragments: [AshPlanning.Fragment.Candidate]

  postgres do
    table "planning_candidates"
    repo ClinicDemo.Repo

    references do
      reference :run, on_delete: :restrict
    end
  end

  changes do
    change ClinicDemo.Planning.Changes.ApplyCandidate,
      on: [:update],
      where: action_is(:apply)
  end

  relationships do
    belongs_to :run, ClinicDemo.Planning.Run do
      public? true
      define_attribute? false
      description "The run that proposed the candidate."
    end

    has_many :check_results, ClinicDemo.Planning.CheckResult do
      public? true
      sort inserted_at: :asc
      description "Every check of the candidate, oldest first."
    end
  end

  policies do
    policy action_type(:read) do
      description "Candidates are readable by anything that can reach the application."
      authorize_if always()
    end

    policy action([:propose, :record_check, :mark_stale, :supersede]) do
      description "The planner writes a candidate's plan, checks and freshness; no person does."
      authorize_if ClinicDemo.Planning.Checks.Machinery
    end

    policy action([:approve, :apply]) do
      description "Approving and applying need both four-eyes sign-offs, from one of the two approvers."
      authorize_if ClinicDemo.Planning.Checks.FourEyesSignedOff
    end

    policy action(:reject) do
      description "Either approver (a leadership clinician) may turn a candidate down."
      authorize_if ClinicDemo.Planning.Checks.Approver
    end
  end
end
