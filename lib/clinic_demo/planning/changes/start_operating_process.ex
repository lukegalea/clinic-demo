defmodule ClinicDemo.Planning.Changes.StartOperatingProcess do
  @moduledoc """
  When a roster assignment is placed, starts the clinic's existing operating
  process for the appointment **only where one exists** to start: the
  `appointment_visit` process is published, and the appointment has no instance
  yet.

  Same pattern as `ClinicDemo.Scheduling.Changes.StartVisitProcess` (the process is
  started `after_action`, inside the writer's transaction, and a failure to start
  refuses the write rather than being swallowed), but conditional:

    * every appointment booked through `Appointment :book` already has its visit
      instance, so for those this does nothing. An assignment is not a second way
      to start a visit;
    * an appointment that has no instance (booked before the process existed, or
      its instance never started) gets one now, so a covered visit is never one
      nothing is watching;
    * where the process is not published at all, there is nothing to start and the
      placement proceeds.

  The roster never creates a process definition and never starts a different one.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Ash.Error.Changes.InvalidChanges
  alias ClinicDemo.Rules
  alias ClinicDemo.Scheduling.Appointment
  alias ClinicDemo.Visits
  alias ClinicDemo.Visits.Instance

  # The change reads no clock and decides nothing about the appointment: it asks
  # whether an instance exists and starts one if the process does.
  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, assignment ->
      with :ok <- ensure_instance(assignment.appointment_id, context.actor) do
        {:ok, assignment}
      end
    end)
  end

  defp ensure_instance(appointment_id, actor) do
    with true <- process_published?(),
         false <- instance_exists?(appointment_id),
         {:ok, appointment} <- Ash.get(Appointment, appointment_id, authorize?: false) do
      case AshBpmn.start_instance(Visits,
             process: Rules.process_key(),
             subject: appointment,
             actor: actor
           ) do
        {:ok, _instance} ->
          :ok

        {:error, reason} ->
          {:error,
           InvalidChanges.exception(
             message: "could not start the visit process: #{inspect(reason)}"
           )}
      end
    else
      # No published process, an instance already running, or no such appointment
      # any more: nothing to start.
      _nothing_to_start -> :ok
    end
  end

  defp process_published? do
    match?([_ | _], Visits.latest_published_process!(Rules.process_key()))
  end

  defp instance_exists?(appointment_id) do
    Instance
    |> Ash.Query.filter(subject_id == ^appointment_id)
    |> Ash.exists?(authorize?: false)
  end
end
