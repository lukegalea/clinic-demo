defmodule ClinicDemo.Planning.Checks.AppliedByCandidate do
  @moduledoc """
  Gates every write to `Shift` and `Assignment`: it passes only while
  `ClinicDemo.Planning.Changes.ApplyCandidate` is writing a candidate's plan.

  Caller-supplied options are **not trusted**: a `context:` passed to `place_shift`
  proves nothing. The apply change sets a process-local marker
  (`with_marker/2`) around its own writes only, and this check reads that marker.
  On top of it the check re-verifies that

    * the candidate exists, is `:approved` and `:current`, and its four-eyes
      sign-offs are complete,
    * the actor is one of the two signers, and
    * the row being written is the apply's to write: a create names the candidate
      in `candidate_id`; an update (a cancel) targets a row the apply's own diff
      chose to cancel (the marker carries those ids). A replan legitimately cancels
      rows an earlier candidate placed, but nothing the diff did not select.
  """

  use Ash.Policy.SimpleCheck

  alias ClinicDemo.Planning.{Candidate, FourEyes}

  @impl true
  def describe(_opts),
    do: "a four-eyes approved roster candidate is being applied by one of its signers"

  @marker :clinic_planning_apply

  @doc """
  Runs `fun` with the apply marker set for `candidate_id`, and clears it after,
  whatever happens. Only the apply change calls this.
  """
  @spec with_marker(Ecto.UUID.t(), MapSet.t(), (-> result)) :: result when result: term()
  def with_marker(candidate_id, %MapSet{} = cancel_ids, fun) do
    Process.put(@marker, {candidate_id, cancel_ids})
    fun.()
  after
    Process.delete(@marker)
  end

  @impl true
  def match?(%{id: actor_id}, %{subject: subject}, _opts) when is_binary(actor_id) do
    with {candidate_id, cancel_ids} <- Process.get(@marker),
         %Ash.Changeset{} = changeset <- subject,
         true <- row_allowed?(changeset, candidate_id, cancel_ids),
         {:ok, %{disposition: :approved, freshness: :current}} <-
           Ash.get(Candidate, candidate_id, authorize?: false),
         {:ok, signers} <- FourEyes.signers(candidate_id) do
      actor_id in Map.values(signers)
    else
      _ -> false
    end
  end

  def match?(_actor, _context, _opts), do: false

  # A create names its candidate; an update targets a row the diff selected.
  defp row_allowed?(%Ash.Changeset{action_type: :create} = changeset, candidate_id, _cancel_ids),
    do: Ash.Changeset.get_attribute(changeset, :candidate_id) == candidate_id

  defp row_allowed?(
         %Ash.Changeset{action_type: :update, data: %{id: id}},
         _candidate_id,
         cancel_ids
       ),
       do: MapSet.member?(cancel_ids, id)

  defp row_allowed?(_changeset, _candidate_id, _cancel_ids), do: false
end
