defmodule ClinicDemo.Visits.TaskDesk do
  @moduledoc """
  The worklist's three moves on a human task, made as the acting clinician:
  claim it, complete it, hand it to a colleague.

  `ClinicDemo.Visits.HumanTask`'s `:claim_task`, `:complete_task` and
  `:delegate_task` generic actions call these, and the worklist board
  (`ClinicDemoWeb.A2ui.WorklistUI`) offers those actions as card buttons.
  Every move runs through the engine (`AshBpmn.claim_task/2`,
  `complete_task/2`, `delegate_task/2`) so the event log records who did
  what, and a completion routes the visit's token onwards.

  The engine checks candidacy on an explicit claim and nowhere else, so this
  module makes the rest of the checks:

    * an **open** task may be claimed or completed only by one of its
      candidates (completing it records the implicit claim);
    * a **claimed** task may be completed or delegated only by the
      clinician holding it;
    * a task is delegated to an active clinician other than the holder.

  A refusal is an `Ash.Error.Forbidden`, so the surface shows the usual "not
  authorized" line without saying whose task it is.
  """

  require Ash.Query

  alias Ash.Error.Changes.InvalidArgument
  alias Ash.Error.Forbidden
  alias ClinicDemo.Scheduling.Clinician
  alias ClinicDemo.Visits.{HumanTask, TaskCandidate}

  @doc "Claims an open task for the actor. The engine checks candidacy."
  @spec claim(Ecto.UUID.t(), map) :: {:ok, struct} | {:error, term}
  def claim(task_id, actor) do
    with {:ok, task} <- fetch(task_id),
         :ok <- may_take(task, actor) do
      AshBpmn.claim_task(task, actor: actor)
    end
  end

  @doc """
  Completes a task with an outcome, as the actor. An open task is claimed on
  the way, which the engine records.
  """
  @spec complete(Ecto.UUID.t(), atom, String.t() | nil, map) :: {:ok, struct} | {:error, term}
  def complete(task_id, outcome, comment, actor) do
    with {:ok, task} <- fetch(task_id),
         :ok <- may_complete(task, actor) do
      AshBpmn.complete_task(task, outcome: outcome, comment: comment, actor: actor)
    end
  end

  @doc """
  Hands a claimed task from the actor to the active clinician named by
  `to` (full name or licence number, case-insensitive).
  """
  @spec delegate(Ecto.UUID.t(), String.t(), map) :: {:ok, struct} | {:error, term}
  def delegate(task_id, to, actor) do
    with {:ok, task} <- fetch(task_id),
         :ok <- holds(task, actor),
         {:ok, colleague} <- colleague(to, actor) do
      AshBpmn.delegate_task(task,
        to_principal: %{type: :user, id: colleague.id},
        actor: actor
      )
    end
  end

  defp fetch(task_id) do
    case Ash.get(HumanTask, task_id, authorize?: false) do
      {:ok, task} -> {:ok, task}
      {:error, _not_found} -> forbidden()
    end
  end

  defp may_complete(%{status: :open} = task, actor), do: may_take(task, actor)
  defp may_complete(%{status: :claimed} = task, actor), do: holds(task, actor)
  defp may_complete(_task, _actor), do: forbidden()

  defp may_take(%{status: :open, id: task_id}, %{id: actor_id}) do
    candidate? =
      TaskCandidate
      |> Ash.Query.filter(
        task_id == ^task_id and principal_type == :user and principal_id == ^actor_id
      )
      |> Ash.exists?(authorize?: false)

    if candidate?, do: :ok, else: forbidden()
  end

  defp may_take(_task, _actor), do: forbidden()

  defp holds(%{status: :claimed, assignee_id: holder}, %{id: holder}) when not is_nil(holder),
    do: :ok

  defp holds(_task, _actor), do: forbidden()

  defp colleague(to, actor) do
    wanted = to |> to_string() |> String.trim() |> String.downcase()

    matches =
      Clinician
      |> Ash.Query.filter(active == true)
      |> Ash.read!(authorize?: false)
      |> Enum.filter(fn clinician ->
        wanted != "" and
          (String.downcase(clinician.full_name) == wanted or
             String.downcase(clinician.license_number || "") == wanted)
      end)

    case matches do
      [%{id: id}] when id == actor.id ->
        invalid("you already hold this task")

      [colleague] ->
        {:ok, colleague}

      [] ->
        invalid("no active clinician has that name or licence number")

      [_ | _] ->
        invalid("more than one clinician has that name; use the licence number")
    end
  end

  defp forbidden, do: {:error, Forbidden.exception([])}

  defp invalid(message),
    do: {:error, InvalidArgument.exception(field: :to, message: message)}
end
