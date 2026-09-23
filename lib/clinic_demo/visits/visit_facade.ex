defmodule ClinicDemo.Visits.VisitFacade do
  @moduledoc """
  The engine facade behind the check-in and no-show row actions.

  The board and the schedule are two windows on one visit, and their
  buttons mean the same thing either place: the person at the front desk
  says "they arrived" (or "they never came"), and it is the *process* that
  turns that into the appointment's state. So the surfaces' `check_in` and
  `mark_no_show` row actions declare `via` and land here instead of
  running the Ash action directly:

    1. Find the appointment's running instance and its open `CheckIn`
       work item.
    2. Complete that task through `AshBpmn.complete_task` with the
       outcome the button means (`:arrived` / `:no_show`).
    3. The token advances and the engine's invoker calls
       `Appointment.check_in` / `mark_no_show` itself — with its own
       guards and the compliance bundle, exactly as it would from the
       worklist.

  One button, one path: a check-in that went around the process would let
  the board and the token disagree about where a visit is.

  ## The fallback

  When no open `CheckIn` task exists the visit cannot be advanced through
  the engine any more — the instance has already moved past check-in or
  ended. Rather than a dead button state, the facade falls back to the
  direct action, whose own `CurrentStatusIn` guard decides whether the
  transition still makes sense. A comment sits at the call site too, so
  nobody reads the direct path as a second, sanctioned way in.

  Returns the via contract's shapes: `:ok`, `{:ok, term}`, or
  `{:error, Ash.Error.t()}`.
  """

  alias ClinicDemo.Scheduling
  alias ClinicDemo.Scheduling.Appointment
  alias ClinicDemo.Visits.HumanTask
  alias ClinicDemo.Visits.Instance

  require Ash.Query

  @check_in_node "CheckIn"

  @doc """
  The `via` delegate for the board's and the schedule's check-in /
  no-show row actions. `surface` only labels the completion recorded in
  the engine's event log.
  """
  def check_in_task(%{record: %Appointment{} = appointment, action: :check_in} = ctx, surface) do
    complete(appointment, :arrived, ctx.actor, surface)
  end

  def check_in_task(%{record: %Appointment{} = appointment, action: :mark_no_show} = ctx, surface) do
    complete(appointment, :no_show, ctx.actor, surface)
  end

  defp complete(appointment, outcome, actor, surface) do
    case open_check_in_task(appointment) do
      %HumanTask{} = task ->
        with {:ok, _completed} <-
               AshBpmn.complete_task(task,
                 outcome: outcome,
                 comment: "via the #{surface} surface",
                 actor: actor
               ) do
          {:ok, Scheduling.get_appointment!(appointment.id)}
        end

      # Fallback: the visit's token has already moved past CheckIn or the
      # instance has ended, so there is nothing left to complete through
      # the engine. The direct action still applies its own guard — the
      # surface never reaches around a refusal by landing here.
      nil ->
        direct(appointment, outcome, actor)
    end
  end

  defp direct(appointment, :arrived, actor), do: Scheduling.check_in_appointment(appointment, actor: actor)

  defp direct(appointment, :no_show, actor),
    do: Scheduling.mark_appointment_no_show(appointment, actor: actor)

  # The appointment's still-running instance and its open CheckIn work
  # item, if any. Booking starts exactly one instance per appointment, so
  # this is two indexed reads, not a scan.
  defp open_check_in_task(appointment) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(subject_id == ^appointment.id and status == :running)
    |> Ash.read!(authorize?: false)
    |> Enum.find_value(fn instance ->
      HumanTask
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(
        instance_id == ^instance.id and node_id == ^@check_in_node and
          status in [:open, :claimed]
      )
      |> Ash.read_one!(authorize?: false)
    end)
  end
end
