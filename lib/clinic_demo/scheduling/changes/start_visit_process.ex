defmodule ClinicDemo.Scheduling.Changes.StartVisitProcess do
  @moduledoc """
  Starts an `appointment_visit` instance for a newly booked appointment.

  This is the one line that joins the two halves of the demo. Booking is an
  ordinary Ash create; the process is started `after_action`, once the
  appointment has an id for the instance to point at.

  Two decisions worth naming:

  **It runs inside the booking transaction.** `after_action` in Ash runs before
  the transaction commits, so an appointment and its instance arrive together or
  not at all. A booking whose process failed to start would be a visit nothing
  is watching, which is worse than a booking that failed.

  **It does not swallow the error.** There is no published process in a fresh
  database, and booking will refuse until `ClinicDemo.Rules.install!/0` has run
  (`mix seed` does it). That is deliberate: a demo that quietly booked
  appointments with no process would be a demo whose second half never ran.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidChanges

  # Temporal safety (declared), with the one honest caveat spelled out: the
  # process instance this starts is NOT a temporal resource, so its own
  # timestamps are the wall clock even when the booking is back-dated with
  # `as_of:` (the seeded history does exactly that). That is the intended
  # shape — the engine's instances record when they were STARTED, the
  # appointment's periods record when each stage took effect — and nothing
  # here reads a clock to decide anything about the appointment.
  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, appointment ->
      case AshBpmn.start_instance(ClinicDemo.Visits,
             process: ClinicDemo.Rules.process_key(),
             subject: appointment,
             actor: context.actor
           ) do
        {:ok, _instance} ->
          {:ok, appointment}

        {:error, reason} ->
          {:error,
           InvalidChanges.exception(
             message: "could not start the visit process: #{inspect(reason)}"
           )}
      end
    end)
  end
end
