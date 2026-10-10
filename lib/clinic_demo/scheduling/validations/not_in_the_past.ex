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
      DateTime.compare(value, reference_instant(changeset)) == :lt -> error(opts)
      true -> :ok
    end
  end

  # The rule is "a slot may not be booked or moved into the past". On a
  # temporal resource the write itself has an instant — `as_of`, now when the
  # caller passes none — and "the past" is relative to THAT instant, not to
  # the wall clock: back-dating a booking to yesterday may put its slot
  # tomorrow, and that is exactly what the clinic meant. This is what makes
  # the seeded history writable through the actions (a booking as of three
  # hours ago for a slot two hours ago is legal; the slot was in the visit's
  # future).
  defp reference_instant(changeset) do
    case changeset.as_of do
      %DateTime{} = as_of -> as_of
      _ -> DateTime.utc_now()
    end
  end

  # Temporal safety (declared): the clock this validation reads is the
  # write's own instant — `as_of`, resolved by the data layer for the same
  # write — never a second, independent wall-clock read.
  @impl true
  def temporal_safe?(_opts), do: true

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
