defmodule ClinicDemo.Judgments do
  @moduledoc """
  The clinic's judgment pipeline: recorded observations and the temporal
  facts they admit (P4-S4, the facts temporal-swap's first-facts slice).

  Two resources, both fragments on this app's own base — the package never
  defines a persisted resource; the host owns the table so the audit log
  and the platform apply to every judgment:

    * `Observation` — the judgment ledger (`AshJudgments.Ledger.Fragment`):
      one append-only row per judgment, `state_digest` the input hash the
      decision saw. Replaying the event log rebuilds it without consulting
      any model.
    * `Fact` — the materialised-facts table
      (`AshJudgments.Facts.TemporalFragment`): the born-temporal host
      pattern proven in VPM-51, there was no legacy table to migrate.

  `Triage` is the minimal admission path over them: extract the state a
  triage judgment saw, record the observation, admit the patient-acuity
  fact through `AshJudgments.Facts.Materialiser` citing the observation —
  the C1 evidence assertion active from day one. Since P4-S5 the admission
  rides the scheduling domain's own `:record_triage` action
  (`ClinicDemo.Scheduling.Changes.AdmitAcuityFact`), so every path that
  records a triage answer — the visit process, the task list, the seeds —
  accumulates the judgment record in the same transaction, and a cold
  clone replays the ledger and the fact periods from the event log itself.

  The read surfaces: `AshJudgments.Query.status/tri_state` for the
  as-of-now standings (what `ClinicDemo.Scheduling.Calculations.AcuityFact`
  puts on the board and schedule cards), and `Standings.status_at/
  acuity_status_at/tri_state_at` for the as-of variant — the standing at
  an instant T, straight off the period containment.

  The architectural line is the decisions domain's, extended one step: a
  decision decides, `Scheduling` acts, and this domain keeps the record —
  what was judged, on what state, and what was admitted as fact.
  """

  use Ash.Domain

  resources do
    resource ClinicDemo.Judgments.Observation do
      define :record_observation, action: :record
      define :get_observation, action: :read, get_by: [:id]
      define :list_observations, action: :read
    end

    resource ClinicDemo.Judgments.Fact do
      define :list_facts, action: :read
      define :facts_for_subject, action: :for_subject, args: [:subject, :predicate]

      define :get_fact, action: :read, get_by: [:id]
    end
  end
end
