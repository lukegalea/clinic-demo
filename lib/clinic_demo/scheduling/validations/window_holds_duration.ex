defmodule ClinicDemo.Scheduling.Validations.WindowHoldsDuration do
  @moduledoc """
  A visit request's window must be long enough to hold the visit: `latest_end_at`
  is at least `duration_minutes` after `earliest_start_at`. A window that cannot
  hold its own visit is refused at the request, not discovered as an infeasible plan.
  """

  use Ash.Resource.Validation

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def validate(changeset, _opts, _context) do
    from = Ash.Changeset.get_attribute(changeset, :earliest_start_at)
    to = Ash.Changeset.get_attribute(changeset, :latest_end_at)
    minutes = Ash.Changeset.get_attribute(changeset, :duration_minutes)

    cond do
      is_nil(from) or is_nil(to) or is_nil(minutes) ->
        :ok

      DateTime.diff(to, from, :second) >= minutes * 60 ->
        :ok

      true ->
        {:error, field: :latest_end_at, message: "the window is shorter than the visit"}
    end
  end
end
