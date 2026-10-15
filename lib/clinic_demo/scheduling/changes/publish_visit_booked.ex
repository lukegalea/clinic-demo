defmodule ClinicDemo.Scheduling.Changes.PublishVisitBooked do
  @moduledoc """
  The ledger half of a booking: the visit's expected value enters the
  ledger in the same transaction as the booking itself, after
  `StartVisitProcess` has started the walk.

  A five-line declaration by design (BPSim §2a): all payload-building,
  provenance and idempotency live in `ClinicDemo.BusinessEvents.Publish`.
  The hook is atomic with the write — a booking and its value event exist
  together or not at all — and `as_of`-correct by construction, so the
  seeds' back-dated bookings land in the ledger at the instant the
  history says they happened.
  """

  use Ash.Resource.Change

  alias ClinicDemo.BusinessEvents.Publish

  # Temporal safety (declared): the hook reads no clock of its own — the
  # event's truth instant is the write's `as_of`, already resolved onto
  # the changeset. The ledger's `observed_at` is the wall clock by
  # definition (when the clinic knew), not a temporal read.
  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, appointment ->
      Publish.visit_booked(changeset, appointment)
      {:ok, appointment}
    end)
  end
end
