defmodule ClinicDemo.Planning.FourEyes do
  @moduledoc """
  The four-eyes approval of a roster candidate: one `candidate_four_eyes` process
  instance per candidate, with a pair of human tasks, the clinic manager's and
  the head vet's, that run in parallel.

      {:ok, _instance} = FourEyes.start(candidate)
      FourEyes.sign(task_id, :approved, actor)   # the first approver: nothing else happens
      FourEyes.sign(task_id, :approved, actor)   # the second approver: approve + apply

  The process only collects the two decisions; it never writes a Shift or an
  Assignment. When both tasks are `approved` by two different clinicians, `sign/3`
  runs `Candidate.approve` and `Candidate.apply` **as the second approver**, whose
  `apply` writes the schedule in one transaction. If either approver `rejected`,
  the candidate is rejected and the instance is cancelled through the engine
  (`AshBpmn.cancel_instance/2`), which kills the other approver's parked token and
  cancels their task (status `:cancelled`), so no orphan task is left on a worklist.

  Authority lives in the policies, not here: `approve` and `apply` are refused
  unless `signers/1` is complete and the actor is one of the signers
  (`ClinicDemo.Planning.Checks.FourEyesSignedOff`), so calling them any other way
  changes nothing.
  """

  require Ash.Query

  alias Ash.Error.Forbidden
  alias ClinicDemo.Planning
  alias ClinicDemo.Planning.Machinery
  alias ClinicDemo.Rules
  alias ClinicDemo.Visits
  alias ClinicDemo.Visits.{HumanTask, Instance, TaskDesk}

  @subject_type "Elixir.ClinicDemo.Planning.Candidate"
  @manager_node "ManagerSignoff"
  @head_vet_node "HeadVetSignoff"

  @doc """
  Starts the approval process for `candidate`. The two sign-off tasks are open for
  the clinic manager and the head vet as soon as it returns.
  """
  @spec start(struct(), map()) :: {:ok, map()} | {:error, term()}
  def start(candidate, actor \\ Machinery.actor()) do
    AshBpmn.start_instance(Visits,
      process: Rules.four_eyes_process_key(),
      subject: candidate,
      actor: actor
    )
  end

  @doc "The candidate's two sign-off tasks (open, claimed or completed), by node."
  @spec tasks(Ecto.UUID.t()) :: %{optional(String.t()) => struct()}
  def tasks(candidate_id) do
    instance_ids =
      Instance
      |> Ash.Query.filter(subject_id == ^candidate_id and subject_type == ^@subject_type)
      |> Ash.Query.select([:id])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)

    HumanTask
    |> Ash.Query.filter(instance_id in ^instance_ids)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.node_id, &1})
  end

  @doc """
  The two signers, `%{"ManagerSignoff" => clinician_id, "HeadVetSignoff" =>
  clinician_id}`, when both tasks are completed `approved` by two different
  clinicians; `:incomplete` otherwise.
  """
  @spec signers(Ecto.UUID.t()) :: {:ok, %{String.t() => Ecto.UUID.t()}} | :incomplete
  def signers(candidate_id) do
    tasks = tasks(candidate_id)

    signed =
      for node <- [@manager_node, @head_vet_node],
          %{status: :completed, outcome: "approved", decided_by_id: id} when is_binary(id) <-
            [Map.get(tasks, node)],
          into: %{},
          do: {node, id}

    if map_size(signed) == 2 and signed[@manager_node] != signed[@head_vet_node],
      do: {:ok, signed},
      else: :incomplete
  end

  @doc """
  Records one approver's decision (`:approved` or `:rejected`) on their task, as
  them. Refused (`Ash.Error.Forbidden`) if the actor is not a candidate for the
  task, already signed the other one, or the candidate is already decided.

  Returns `{:ok, candidate}` with the candidate as it stands afterwards:
  unchanged (still `:proposed`) after the first approval, `:applied` after the
  second, `:rejected` after a rejection, or `:rejected` and `:stale` when the
  apply was refused because a source drifted (then `{:error, error}` carries the
  refusal).
  """
  @spec sign(Ecto.UUID.t(), :approved | :rejected, map()) ::
          {:ok, struct()} | {:error, term()}
  def sign(task_id, decision, actor) when decision in [:approved, :rejected] do
    with {:ok, task, candidate_id} <- fetch_task(task_id),
         {:ok, candidate} <- open_candidate(candidate_id),
         :ok <- not_the_other_signer(candidate_id, task, actor),
         {:ok, _task} <- TaskDesk.complete(task.id, decision, nil, actor) do
      settle(candidate, decision, actor)
    end
  end

  # ── settlement ─────────────────────────────────────────────────────────────

  defp settle(candidate, :rejected, actor) do
    cancel(candidate.id)
    Planning.reject_candidate(candidate, %{}, actor: actor)
  end

  defp settle(candidate, :approved, actor) do
    case signers(candidate.id) do
      :incomplete ->
        {:ok, candidate}

      {:ok, _signers} ->
        with {:ok, approved} <- Planning.approve_candidate(candidate, %{}, actor: actor) do
          Planning.apply_candidate(approved, %{}, actor: actor)
        end
    end
  end

  # The other approver's task, if still open, is closed by the planner so it does
  # not linger on a worklist after the candidate is rejected.
  @doc """
  Cancels the candidate's approval instance through the engine: live tokens die and
  open sign-off tasks become `:cancelled`. Used when a candidate is rejected or
  superseded, so no task is left on a worklist for a plan nobody will apply. A
  no-op when there is no running instance.
  """
  @spec cancel(Ecto.UUID.t()) :: :ok
  def cancel(candidate_id) do
    Instance
    |> Ash.Query.filter(
      subject_id == ^candidate_id and subject_type == ^@subject_type and status == :running
    )
    |> Ash.read!(authorize?: false)
    |> Enum.each(&AshBpmn.cancel_instance!/1)
  end

  # ── guards ─────────────────────────────────────────────────────────────────

  # A sign-off task is any task of a candidate's approval instance; the candidate
  # is the instance's subject. A task of another process is not one.
  defp fetch_task(task_id) do
    with {:ok, %{instance_id: instance_id} = task} when not is_nil(instance_id) <-
           Ash.get(HumanTask, task_id, authorize?: false),
         {:ok, %{subject_type: @subject_type, subject_id: candidate_id}} <-
           Ash.get(Instance, instance_id, authorize?: false) do
      {:ok, task, candidate_id}
    else
      _other -> {:error, Forbidden.exception([])}
    end
  end

  defp open_candidate(candidate_id) do
    case Ash.get(Planning.Candidate, candidate_id, authorize?: false) do
      {:ok, %{disposition: :proposed, freshness: :current} = candidate} ->
        {:ok, candidate}

      _decided_or_stale ->
        {:error, Forbidden.exception([])}
    end
  end

  # One person signs one task: the same clinician may not satisfy both, even when
  # they are a candidate for both.
  defp not_the_other_signer(candidate_id, task, %{id: actor_id}) do
    other_signed? =
      candidate_id
      |> tasks()
      |> Enum.any?(fn {_node, other} ->
        other.id != task.id and other.status == :completed and other.decided_by_id == actor_id
      end)

    if other_signed?, do: {:error, Forbidden.exception([])}, else: :ok
  end

  defp not_the_other_signer(_candidate_id, _task, _actor), do: {:error, Forbidden.exception([])}
end
