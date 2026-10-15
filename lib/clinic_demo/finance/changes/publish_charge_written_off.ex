defmodule ClinicDemo.Finance.Changes.PublishChargeWrittenOff do
  @moduledoc """
  The ledger half of a write-off: money already recognized leaves the
  collectable side, and the ledger learns of it as a NEW event
  (`charge_written_off`) — never a rewrite of the completion event
  (BPSim §2a: value revisions are events; corrections are rows).

  A five-line declaration by design; the plumbing lives in
  `ClinicDemo.BusinessEvents.Publish`. The write-off's instant is the
  write's `as_of`, the same rule every temporal write here follows.
  """

  use Ash.Resource.Change

  alias ClinicDemo.BusinessEvents.Publish

  # Temporal safety (declared): the hook reads no clock of its own — the
  # event's truth instant is the write's `as_of`.
  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, charge ->
      Publish.charge_written_off(changeset, charge)
      {:ok, charge}
    end)
  end
end
