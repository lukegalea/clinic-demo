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
