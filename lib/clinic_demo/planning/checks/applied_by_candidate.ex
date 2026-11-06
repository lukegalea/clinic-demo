defmodule ClinicDemo.Planning.Checks.AppliedByCandidate do
  @moduledoc """
  Gates every write to `Shift` and `Assignment`: it passes only while a roster
  candidate is being applied.

  `ClinicDemo.Planning.Changes.ApplyCandidate` runs the writes inside
  `Candidate.apply` with `context: %{planning_apply: %{candidate_id: id}}`. This
  check does not trust that context alone. It also requires that

    * the candidate exists and is `:approved` and `:current` (the apply action's
      own guards, which have passed, but a bare `context:` from anywhere else
      must not pass on its own),
    * the four-eyes sign-offs are complete,
    * the actor is one of the two signers, and
    * a created row names that same candidate in its `candidate_id`.

  So no person can create a `Shift` or an `Assignment` directly: they have no
  approved, fully signed candidate in flight, and the context is not enough.
  """

  use Ash.Policy.SimpleCheck

  alias ClinicDemo.Planning.{Candidate, FourEyes}

  @impl true
  def describe(_opts),
    do: "a four-eyes approved roster candidate is being applied by one of its signers"

  @impl true
  def match?(%{id: actor_id}, %{subject: subject}, _opts) when is_binary(actor_id) do
    with %Ash.Changeset{} = changeset <- subject,
         %{candidate_id: candidate_id} <- changeset.context[:planning_apply],
         true <- candidate_matches?(changeset, candidate_id),
         {:ok, %{disposition: :approved, freshness: :current}} <-
           Ash.get(Candidate, candidate_id, authorize?: false),
         {:ok, signers} <- FourEyes.signers(candidate_id) do
      actor_id in Map.values(signers)
    else
      _ -> false
    end
  end

  def match?(_actor, _context, _opts), do: false

  # A create names its candidate; a cancel of an existing row is scoped by the
  # context alone (the row's own `candidate_id` is the one it was placed by).
  defp candidate_matches?(%Ash.Changeset{action_type: :create} = changeset, candidate_id),
    do: Ash.Changeset.get_attribute(changeset, :candidate_id) == candidate_id

  defp candidate_matches?(%Ash.Changeset{}, _candidate_id), do: true
end
