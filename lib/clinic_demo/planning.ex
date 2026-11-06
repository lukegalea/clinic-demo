defmodule ClinicDemo.Planning do
  @moduledoc """
  The clinic's weekly staffing planner: a constraint-solving **proposal** kernel
  hosted on `ash_planning`.

  A planning run reads the week's demand and availability (`Appointment`
  `status == :scheduled` rows and `Availability`, both temporal, read `as_of` a
  knowledge cutoff), asks the `staffing.policy` decision for the policy
  parameters, hands a bounded problem to a backend, and records what came back as
  **candidates**: proposed shifts and appointment assignments. A candidate is
  inert. It becomes a `Scheduling.Shift` / `Scheduling.Assignment` only when the
  clinic manager AND the head vet both sign it off (a BPMN human-task pair,
  `ClinicDemo.Planning.FourEyes`) and it is applied after a freshness recheck.
  The solver never mutates an appointment, a customer's booking.

  Five resources, each `AshPlanning.Fragment.*` on the clinic's own base:

    * `ModelVersion` — an immutable, content-hashed model + checker + validator.
    * `Binding` — temporal: which pinned definitions answer
      `(model_key, purpose)`.
    * `Run` — one solve request: preparation, solve, completion, optimality kept
      as separate axes.
    * `Candidate` — one proposed plan, with check, freshness and disposition axes.
    * `CheckResult` — the MiniZinc checker's verdict and the independent
      validator's, recorded separately.

  The same loop plans a second thing: one veterinarian's mobile visits for one day
  against a versioned travel matrix (`ClinicDemo.Planning.MobileVisits`). Each plan
  is a `ClinicDemo.Planning.Model`; the five resources are shared.

  The entry points are `ClinicDemo.Planning.WeeklyRoster` and
  `ClinicDemo.Planning.MobileVisits`.
  """

  use Ash.Domain

  resources do
    resource ClinicDemo.Planning.ModelVersion do
      define :draft_model_version, action: :draft
      define :publish_model_version, action: :publish
      define :list_model_versions, action: :read
    end

    resource ClinicDemo.Planning.Binding do
      define :bind_model, action: :bind
      define :rebind_model, action: :rebind
      define :list_bindings, action: :read
    end

    resource ClinicDemo.Planning.Run do
      define :request_run, action: :request
      define :prepare_run, action: :prepare
      define :start_run, action: :start
      define :record_run_result, action: :record_result
      define :list_runs, action: :read
    end

    resource ClinicDemo.Planning.Candidate do
      define :propose_candidate, action: :propose
      define :record_candidate_check, action: :record_check
      define :mark_candidate_stale, action: :mark_stale
      define :approve_candidate, action: :approve
      define :reject_candidate, action: :reject
      define :apply_candidate, action: :apply
      define :supersede_candidate, action: :supersede
      define :list_candidates, action: :read
    end

    resource ClinicDemo.Planning.CheckResult do
      define :record_check_result, action: :record
      define :list_check_results, action: :read
    end
  end
end
