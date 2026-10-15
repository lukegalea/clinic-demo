defmodule ClinicDemo.Scheduling.Changes.PublishVisitCompleted do
  @moduledoc """
  The ledger half of a write-up: the visit's realized value enters the
  ledger in the same transaction, after `RecognizeCharge` — so when a
  catalogue type exists, the charge is already on the books and the
  event reads it (`Finance.charge_for/1`). A visit with no type
  recognizes nothing, and its completion event carries no amount key.

  A five-line declaration by design (BPSim §2a); the plumbing lives in
  `ClinicDemo.BusinessEvents.Publish`. The seeds walk `:complete` twice
  per visited appointment (back-dated write-up plus the present-tense
  re-assert); the event's `delivery_key` collapses the retelling — one
  completion event per visit, ever, the "one charge per visit" ruling
  restated.
  """

  use Ash.Resource.Change

  alias ClinicDemo.BusinessEvents.Publish

  # Temporal safety (declared): the hook reads no clock of its own — the
  # event's truth instant is the write's `as_of`, the same instant
  # `RecognizeCharge` stamps on the charge.
  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, appointment ->
      Publish.visit_completed(changeset, appointment)
      {:ok, appointment}
    end)
  end
end
