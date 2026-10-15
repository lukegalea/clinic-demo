defmodule ClinicDemo.Scheduling.Changes.PublishVisitTriaged do
  @moduledoc """
  The ledger half of a triage write: the decision's urgency enters the
  value ledger in the same transaction, after `AdmitAcuityFact` has kept
  the judgment record.

  A five-line declaration by design (BPSim §2a) — the payload and the
  urgency→band decode live in the mapping rules, the plumbing in
  `ClinicDemo.BusinessEvents.Publish`. The urgency vocabulary is the
  action's own `one_of` constraint, which is exactly the decode's four
  cases — a miss is unrepresentable.

  Emission is live-only for the engine's booking-time triage, per the
  BD-3 RULING (2026-10-15, "the engine's triage event is live-only"):
  for a back-dated (story-replay) booking the engine's write — seed
  mechanics at seed-run wall clock — records no ledger row, and the walk's
  own back-dated `record_triage` lands at the story instant. The
  detection lives in `ClinicDemo.BusinessEvents.Publish.visit_triaged/2`.
  """

  use Ash.Resource.Change

  alias ClinicDemo.BusinessEvents.Publish

  # Temporal safety (declared): the hook reads no clock of its own — the
  # event's truth instant is the write's `as_of` (the seeds back-date
  # triage writes; the ledger records them at that instant).
  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, appointment ->
      Publish.visit_triaged(changeset, appointment)
      {:ok, appointment}
    end)
  end
end
