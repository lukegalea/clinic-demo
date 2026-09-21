defmodule ClinicDemo.Scheduling.Validations.NotInThePast do
  @moduledoc """
  Rejects a datetime that has already happened.

  Implemented as a module rather than an inline function so that the
  introspection tools can report it by name, and so that the atomic
  version below can push the same rule into the update statement.
  """

  use Ash.Resource.Validation

  import Ash.Expr

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def init(opts) do
    if is_atom(opts[:attribute]) and not is_nil(opts[:attribute]) do
      {:ok, opts}
    else
      {:error, "`:attribute` must be the name of a datetime attribute or argument"}
    end
  end

  @impl true
  def describe(opts) do
    [message: "must not be in the past", vars: [field: opts[:attribute]]]
  end

  @impl true
  def validate(changeset, opts, _context) do
    value =
      Ash.Changeset.get_argument_or_attribute(changeset, opts[:attribute])

    cond do
      is_nil(value) -> :ok
      DateTime.compare(value, DateTime.utc_now()) == :lt -> error(opts)
      true -> :ok
    end
  end

  @impl true
  def atomic(_changeset, opts, context) do
    {:atomic, [opts[:attribute]], expr(^atomic_ref(opts[:attribute]) < now()),
     expr(
       error(^InvalidAttribute, %{
         field: ^opts[:attribute],
         value: ^atomic_ref(opts[:attribute]),
         message: ^(context.message || "must not be in the past"),
         vars: %{field: ^opts[:attribute]}
       })
     )}
  end

  defp error(opts) do
    {:error, field: opts[:attribute], message: "must not be in the past"}
  end
end
