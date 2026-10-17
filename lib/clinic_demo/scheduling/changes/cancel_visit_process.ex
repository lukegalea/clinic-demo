defmodule ClinicDemo.Scheduling.Changes.CancelVisitProcess do
  @moduledoc """
  Cancels the visit's running `appointment_visit` instance when the
  appointment is cancelled.

  The visit process has no cancellation path of its own: a booked visit's
  token waits on `CheckIn`, a checked-in one on `Consult`. Without this, a
  cancelled visit left its work item open on the nurse's worklist, and
  completing it there failed, because the engine's `MarkNoShow` then asked
  the machine for a `cancelled -> no_show` move it does not have.

  So `:cancel` stops the process through the engine, `AshBpmn.cancel_instance/2`:
  every live token killed, every open or claimed task cancelled, the task
  timers defused, and an `:instance_cancelled` event written. It runs
  `after_action`, inside the cancel's transaction, so the cancelled visit's
  row and its stopped process's rows commit together or not at all, and a
  failure to stop the process fails the cancel.

  The flight view's live updates are not part of that. `cancel_instance/2`
  runs outside an engine step, so the engine sends its "token killed"
  broadcasts at once rather than after commit: if a later change in the same
  `:cancel` fails and the transaction rolls back, flight viewers have already
  been told the tokens died. A reload shows the truth. The fix belongs in
  ash_bpmn (run `cancel_instance/2` as a locked step).

  An appointment with no running instance (its process already ended, or a
  back-dated cancel in the seeded history whose present re-assert finds the
  instance already cancelled) is left alone.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidChanges
  alias ClinicDemo.Visits.Instance

  require Ash.Query

  # The instance is not temporal (see StartVisitProcess): cancelling it is a
  # present-tense write at the wall clock even when the appointment's cancel
  # is back-dated, and nothing here reads a clock to decide anything about
  # the appointment.
  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, appointment ->
      appointment
      |> running_instances(context.actor)
      |> Enum.reduce_while({:ok, appointment}, &cancel(&1, &2, context.actor))
    end)
  end

  defp cancel(instance, ok, actor) do
    case AshBpmn.cancel_instance(instance, actor: actor) do
      {:ok, _cancelled} ->
        {:cont, ok}

      {:error, reason} ->
        {:halt,
         {:error,
          InvalidChanges.exception(
            message: "could not stop the visit process: #{inspect(reason)}"
          )}}
    end
  end

  # Booking starts exactly one instance per appointment; read the running
  # ones by subject (an indexed read) rather than assuming the count.
  defp running_instances(appointment, actor) do
    Instance
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(subject_id == ^appointment.id and status == :running)
    |> Ash.read!()
  end
end
