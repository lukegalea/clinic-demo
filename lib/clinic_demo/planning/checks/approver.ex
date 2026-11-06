defmodule ClinicDemo.Planning.Checks.Approver do
  @moduledoc """
  Passes when the actor is an active clinician holding a leadership position (the
  clinic manager or the head vet): someone who may sign a roster candidate off or
  turn it down.
  """

  use Ash.Policy.SimpleCheck

  require Ash.Query

  alias ClinicDemo.Scheduling.Clinician

  @impl true
  def describe(_opts), do: "the actor is the clinic manager or the head vet"

  @impl true
  def match?(%{id: id}, _context, _opts) when is_binary(id), do: approver?(id)
  def match?(_actor, _context, _opts), do: false

  @doc "Whether the clinician `id` is an active leadership clinician."
  @spec approver?(String.t()) :: boolean()
  def approver?(id) do
    Clinician
    |> Ash.Query.filter(id == ^id and active == true and not is_nil(leadership))
    |> Ash.exists?(authorize?: false)
  rescue
    Ecto.Query.CastError -> false
  end
end
