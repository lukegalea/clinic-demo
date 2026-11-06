defmodule ClinicDemo.Planning.Checks.FourEyesSignedOff do
  @moduledoc """
  Passes for `Candidate.approve` and `Candidate.apply` only when the candidate's
  four-eyes process has both sign-offs (the clinic manager's AND the head vet's,
  two different clinicians, both `approved`) and the actor is one of the two
  signers. No other route reaches either action.
  """

  use Ash.Policy.SimpleCheck

  alias ClinicDemo.Planning.FourEyes

  @impl true
  def describe(_opts),
    do: "the clinic manager and the head vet have both signed the candidate off"

  @impl true
  def match?(%{id: actor_id}, %{subject: %Ash.Changeset{data: %{id: candidate_id}}}, _opts)
      when is_binary(actor_id) do
    case FourEyes.signers(candidate_id) do
      {:ok, signers} -> actor_id in Map.values(signers)
      :incomplete -> false
    end
  end

  def match?(_actor, _context, _opts), do: false
end
