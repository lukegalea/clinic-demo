defmodule ClinicDemo.Events.EventTest do
  @moduledoc """
  The audit resource reads the `ash_events` table the compliance install's
  migration created, and it cannot write it — an audit log with an
  application-facing write path is not an audit log.
  """

  use ClinicDemo.DataCase, async: true

  alias Ash.Resource.Info
  alias ClinicDemo.Events.Event

  test "reads the event log table (empty until the projector runs)" do
    # The guard path in this app is synchronous and appends no rows, so the
    # honest state of this surface is an empty list. When the event
    # projector is wired in (deferred), rows appear here with no change to
    # this resource.
    assert [] = Event |> Ash.Query.for_read(:read) |> Ash.read!(authorize?: false)
  end

  test "there is no sanctioned write path" do
    actions = Info.actions(Event)

    assert actions != []
    assert Enum.all?(actions, &(&1.type == :read))
  end
end
