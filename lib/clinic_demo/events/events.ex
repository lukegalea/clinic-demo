defmodule ClinicDemo.Events do
  @moduledoc """
  Audit visibility: read-only access to the `ash_events` event log.

  The compliance writes in this app are synchronous, so nothing in the
  guard path appends to the log today — the table exists (its migration
  ships with the compliance install) and this domain reads it. When the
  event projector is wired to append (a deferred follow-up), the rows land
  here and the /events surface picks them up with no further changes.
  """

  use Ash.Domain

  resources do
    resource ClinicDemo.Events.Event
  end
end
