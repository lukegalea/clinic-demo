defmodule ClinicDemo.Judgments.Observation do
  @moduledoc """
  The judgment ledger: one append-only row per judgment the clinic records
  (P4-S4; the host shape `AshJudgments.Ledger` spells out).

  `AshJudgments.Ledger.Fragment` supplies the RFC §5 field set, the `:record`
  create (every field input — including the answer — so replaying the event
  log rebuilds the row and no model is ever consulted again), the one
  sanctioned erasure update, and the digest reads. The derived fields —
  `record_hash`, `cache_key`, the stack's region — are pure functions of the
  inputs and host config, identical on replay.

  Writes ride the central event log (`ClinicDemo.Events.Event`) like every
  other audited resource in this app: the audit trail for a judgment is the
  same one the appointments and the DMN evaluations already feed. Reads are
  currently test-surface only; P4-S5 wires the standings views over them.
  """

  use Ash.Resource,
    domain: ClinicDemo.Judgments,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events],
    fragments: [AshJudgments.Ledger.Fragment]

  postgres do
    table "judgment_observations"
    repo ClinicDemo.Repo
  end

  events do
    event_log ClinicDemo.Events.Event
    create_timestamp :recorded_at
  end
end
