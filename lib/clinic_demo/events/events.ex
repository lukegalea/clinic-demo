defmodule ClinicDemo.Events do
  @moduledoc """
  Audit visibility: read-only access to the `ash_events` event log.

  The log is written by ash_events itself: `ClinicDemo.Events.Event` is the
  event-log resource, and the story resources (appointments, patients,
  clinicians, DMN evaluations) carry the `AshEvents.Events` extension, so
  every wrapped action appends a row in the same transaction as its write.
  Rows land here and the /events surface picks them up with no further
  changes.
  """

  use Ash.Domain

  resources do
    resource ClinicDemo.Events.Event
  end
end
