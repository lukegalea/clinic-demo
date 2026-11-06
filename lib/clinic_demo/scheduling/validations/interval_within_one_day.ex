defmodule ClinicDemo.Scheduling.Validations.IntervalWithinOneDay do
  @moduledoc """
  A half-open interval `[starts_at, ends_at)` that is non-empty and does not
  cross UTC midnight: `ends_at` is after `starts_at` and no later than the
  start of the next day.

  The two attributes default to `:starts_at` and `:ends_at`; `starts:` and `ends:`
  name others (a visit request's window is `earliest_start_at` / `latest_end_at`).
  """

  use Ash.Resource.Validation

  # Reads only the changeset's own attributes.
  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def validate(changeset, opts, _context) do
    starts = Keyword.get(opts, :starts, :starts_at)
    ends = Keyword.get(opts, :ends, :ends_at)
    starts_at = Ash.Changeset.get_attribute(changeset, starts)
    ends_at = Ash.Changeset.get_attribute(changeset, ends)

    cond do
      is_nil(starts_at) or is_nil(ends_at) ->
        :ok

      DateTime.compare(ends_at, starts_at) != :gt ->
        {:error, field: ends, message: "must be after the start (half-open interval)"}

      DateTime.compare(ends_at, midnight_after(starts_at)) == :gt ->
        {:error, field: ends, message: "must not cross midnight"}

      true ->
        :ok
    end
  end

  defp midnight_after(%DateTime{} = starts_at) do
    starts_at
    |> DateTime.to_date()
    |> Date.add(1)
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end
end
