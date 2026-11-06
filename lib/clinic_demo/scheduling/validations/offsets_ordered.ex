defmodule ClinicDemo.Scheduling.Validations.OffsetsOrdered do
  @moduledoc "A shift template's end offset is after its start offset (half-open, non-empty)."

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    start = Ash.Changeset.get_attribute(changeset, :start_offset_minutes)
    stop = Ash.Changeset.get_attribute(changeset, :end_offset_minutes)

    if is_integer(start) and is_integer(stop) and stop <= start do
      {:error, field: :end_offset_minutes, message: "must be after the start offset"}
    else
      :ok
    end
  end
end
