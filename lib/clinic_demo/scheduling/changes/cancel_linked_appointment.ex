defmodule ClinicDemo.Scheduling.Changes.CancelLinkedAppointment do
  @moduledoc """
  When a visit request is cancelled, the appointment a plan booked for it is
  cancelled too, in the same transaction, as the same person and for the same reason.

  A request that was never scheduled has no appointment and nothing happens. The
  appointment's own cancellation (`Appointment.cancel`) stops its visit process and
  publishes the loss; this change only makes sure a cancelled request cannot leave
  a live booking behind.
  """

  use Ash.Resource.Change

  alias ClinicDemo.Scheduling

  # Reads and writes other rows at the write's own instant; no clock of its own.
  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, request ->
      case request.appointment_id do
        nil -> {:ok, request}
        appointment_id -> cancel(request, appointment_id, context)
      end
    end)
  end

  defp cancel(request, appointment_id, context) do
    reason = request.cancellation_reason || "visit request cancelled"

    with {:ok, appointment} <- Scheduling.get_appointment(appointment_id, actor: context.actor),
         {:ok, _cancelled} <-
           open_cancel(appointment, reason, context.actor) do
      {:ok, request}
    end
  end

  # An appointment that is already closed (cancelled directly, completed) needs no
  # second cancellation; the request still ends cancelled.
  defp open_cancel(%{status: status} = appointment, reason, actor)
       when status in [:scheduled, :checked_in],
       do: Scheduling.cancel_appointment(appointment, reason, actor: actor)

  defp open_cancel(appointment, _reason, _actor), do: {:ok, appointment}
end
