defmodule ClinicDemo.Visits.TaskDesk do
  @moduledoc """
  The worklist's three moves on a human task, made as the acting clinician:
  claim it, complete it, hand it to a colleague.

  `ClinicDemo.Visits.HumanTask`'s generic actions call these: `:claim_task`,
  `:delegate_task`, and the completions (`:complete_task` and its per-step
  forms). The worklist board (`ClinicDemoWeb.A2ui.WorklistUI`) offers them
  as card buttons.
  Each one reads the task as the actor and calls the engine
  (`AshBpmn.claim_task/2`, `complete_task/2`, `delegate_task/2`), which
  decides who may act: a candidate claims or completes an open task, only
  the holder completes or delegates a claimed one, and the delegate must be
  one of the task's candidates. The event log records the actor as the
  person who acted, and a completion routes the visit's token onwards.

  What this module adds is the clinic's own part:

    * the outcome must be one the task's step declares (its `:outcomes`).
      The engine records whatever outcome it is given, and the visit's
      gateways route an outcome they do not name down their default flow,
      so "written up" on a check-in would mark the animal a no-show;
    * the delegate is an active clinician other than the actor;
    * the engine's refusals become errors the surface can show. Not being a
      candidate or the holder is an `Ash.Error.Forbidden` (the usual "not
      authorized" line, without saying whose task it is); a delegate who is
      not a candidate is an error on the picker.
  """

  alias Ash.Error.Changes.InvalidArgument
  alias Ash.Error.Forbidden
  alias ClinicDemo.Scheduling.Clinician
  alias ClinicDemo.Visits.Calculations.OutcomeChoices
  alias ClinicDemo.Visits.HumanTask

  @doc "Claims an open task for the actor."
  @spec claim(Ecto.UUID.t(), map) :: {:ok, struct} | {:error, term}
  def claim(task_id, actor) do
    with {:ok, task} <- fetch(task_id, actor) do
      task |> AshBpmn.claim_task(actor: actor) |> refusals()
    end
  end

  @doc """
  Completes a task with one of its step's outcomes, as the actor. An open
  task is claimed on the way, which the engine records.
  """
  @spec complete(Ecto.UUID.t(), atom, String.t() | nil, map) :: {:ok, struct} | {:error, term}
  def complete(task_id, outcome, comment, actor) do
    with {:ok, task} <- fetch(task_id, actor, [:outcomes]),
         :ok <- declared(task, outcome) do
      task
      |> AshBpmn.complete_task(outcome: outcome, comment: comment, actor: actor)
      |> refusals()
    end
  end

  @doc "Hands a claimed task from the actor to the clinician `delegate_id`."
  @spec delegate(Ecto.UUID.t(), Ecto.UUID.t(), map) :: {:ok, struct} | {:error, term}
  def delegate(task_id, delegate_id, actor) do
    with {:ok, task} <- fetch(task_id, actor),
         {:ok, colleague} <- colleague(delegate_id, actor) do
      task
      |> AshBpmn.delegate_task(to_principal: %{type: :user, id: colleague.id}, actor: actor)
      |> refusals()
    end
  end

  defp fetch(task_id, actor, load \\ []) do
    case Ash.get(HumanTask, task_id, actor: actor, load: load) do
      {:ok, task} -> {:ok, task}
      {:error, _not_found} -> forbidden()
    end
  end

  # A standalone approval has no declared outcomes (`nil`); none run here,
  # but such a task would take whatever the picker offers.
  defp declared(%{outcomes: nil}, _outcome), do: :ok

  defp declared(%{outcomes: outcomes}, outcome) do
    if to_string(outcome) in outcomes do
      :ok
    else
      invalid(
        :outcome,
        "is not an outcome of this step; choose #{OutcomeChoices.phrase(outcomes)}"
      )
    end
  end

  defp colleague(delegate_id, %{id: actor_id}) when delegate_id == actor_id,
    do: invalid(:delegate_id, "is you; choose a colleague")

  defp colleague(delegate_id, actor) do
    case Ash.get(Clinician, delegate_id, actor: actor) do
      {:ok, %{active: true} = colleague} -> {:ok, colleague}
      _inactive_or_missing -> invalid(:delegate_id, "is not an active clinician")
    end
  end

  # The engine refuses with an ArgumentError whose text names task and
  # principal ids, which is for logs, not for the person at the board.
  defp refusals({:error, %ArgumentError{message: "the delegate " <> _}}),
    do: invalid(:delegate_id, "is not one of this task's candidates")

  defp refusals({:error, %ArgumentError{}}), do: forbidden()
  defp refusals(result), do: result

  defp forbidden, do: {:error, Forbidden.exception([])}

  defp invalid(field, message),
    do: {:error, InvalidArgument.exception(field: field, message: message)}
end
