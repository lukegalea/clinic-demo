defmodule ClinicDemo.Scheduling.Changes.DeriveAvailabilityDate do
  @moduledoc """
  Sets an availability's calendar `date` from its `starts_at` (UTC), so the date
  and the interval can never disagree.
  """

  use Ash.Resource.Change

  # A pure function of the changeset's own `starts_at`; no clock, no I/O.
  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :starts_at) do
      %DateTime{} = starts_at ->
        Ash.Changeset.force_change_attribute(changeset, :date, DateTime.to_date(starts_at))

      _ ->
        changeset
    end
  end
end
