defmodule ClinicDemo.Scheduling.Validations.LocationMatchesMode do
  @moduledoc """
  An appointment's `location_mode` and its service location agree: a `:mobile`
  visit names the place the veterinarian drives to, and an `:in_clinic` or
  `:telehealth` visit names none (the clinic is where the day starts, and a call has
  no place). Reads the `service_location_id` argument.
  """

  use Ash.Resource.Validation

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def validate(changeset, _opts, _context) do
    mode = Ash.Changeset.get_attribute(changeset, :location_mode)
    location = Ash.Changeset.get_argument(changeset, :service_location_id)

    cond do
      mode == :mobile and is_nil(location) ->
        {:error, field: :service_location_id, message: "a mobile visit needs a service location"}

      mode != :mobile and not is_nil(location) ->
        {:error,
         field: :service_location_id, message: "only a mobile visit has a service location"}

      true ->
        :ok
    end
  end
end
