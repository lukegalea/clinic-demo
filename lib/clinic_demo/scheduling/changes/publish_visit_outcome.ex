defmodule ClinicDemo.Scheduling.Changes.PublishVisitOutcome do
  @moduledoc """
  The ledger half of the story's two losses — a cancellation and a
  no-show — as one change module with a `:moment` opt (BPSim §2a):
  expected value that never realized, recorded in the same transaction
  as the lifecycle write.

      change {PublishVisitOutcome, moment: :cancelled}
      change {PublishVisitOutcome, moment: :no_show}

  A five-line declaration by design; the plumbing lives in
  `ClinicDemo.BusinessEvents.Publish`. The cancellation carries the
  reason the desk gave; the no-show carries nothing but the fact.
  """

  use Ash.Resource.Change

  alias ClinicDemo.BusinessEvents.Publish

  # Temporal safety (declared): the hook reads no clock of its own — the
  # event's truth instant is the write's `as_of`.
  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, opts, _context) do
    moment = Keyword.fetch!(opts, :moment)

    Ash.Changeset.after_action(changeset, fn changeset, appointment ->
      publish_moment(moment, changeset, appointment)
      {:ok, appointment}
    end)
  end

  defp publish_moment(:cancelled, changeset, appointment),
    do: Publish.visit_cancelled(changeset, appointment)

  defp publish_moment(:no_show, changeset, appointment),
    do: Publish.visit_no_show(changeset, appointment)
end
