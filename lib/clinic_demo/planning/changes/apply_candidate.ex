defmodule ClinicDemo.Planning.Changes.ApplyCandidate do
  @moduledoc """
  The host side of `Candidate.apply`: a person commits an approved, checked
  candidate by writing the schedule through the domain's own actions, after a
  freshness recheck. What is written is the run's model's
  (`ClinicDemo.Planning.Model.apply_plan/3`): `Shift` and `Assignment` rows for the
  weekly roster; mobile `Appointment`s and `VisitRequest` scheduling for mobile
  visits. The recheck, the transaction, the marker and the settlement are the same.

      # in ClinicDemo.Planning.Candidate
      changes do
        change ClinicDemo.Planning.Changes.ApplyCandidate, on: [:update], where: action_is(:apply)
      end

  `apply` is four-eyes (`ClinicDemo.Planning.Checks.FourEyesSignedOff`), so the
  actor on the changeset is the second approver, and every write below is made as
  them.

  ## Order of events

  The fragment's `apply` validations (approved, correct, current) have already
  passed. Inside the action's transaction, before the disposition is written:

    1. **Recheck every source.** The run's problem payload carries the snapshot
       envelope (its digest verified). The inputs are read again *now* by the same
       reader that built them (the model's `current_inputs/1`); any input that was added, removed or whose content
       hash moved (a booking, a rescheduled or cancelled appointment, a changed
       availability, a shift applied by another candidate) is *drift* and refuses
       the apply. Nothing is written.
    2. **Diff against what is applied.** The candidate is a whole-scope plan (a week;
       a day's route). What is already applied and the plan keeps is left alone (and
       counted as preserved); what the plan drops is cancelled; what is new is placed.
    3. **Write, in one transaction.** Cancels first, then placements, as the
       approving person, with a process-local marker set only around these writes
       (`Checks.AppliedByCandidate`; the `Shift`/`Assignment` policy trusts that
       marker, never caller options, and re-verifies the candidate). The first refusal rolls every write back.
    4. **Settlement.** Drift and a write-time refusal both end the candidate
       `:rejected` AND `:stale`, after the rollback: `mark_stale` (planner) first,
       then `reject` (the approving person). That order is forced by the guards:
       `mark_stale` is refused once a candidate is decided, while `reject` is
       allowed from `:approved` whatever its freshness. The error is returned
       either way; never an approved-looking stale row.

  On success the returned candidate carries the outcome as metadata
  (`record.__metadata__[:planning_apply]`): the roster's `placed_shifts`,
  `placed_assignments`, `cancelled_shifts`, `cancelled_assignments`,
  `preserved_shifts`, `preserved_assignments`; mobile visits' `booked_visits`,
  `moved_visits`, `preserved_visits`.

  The recheck and the writes share one transaction, but a booking that commits
  between the recheck and this transaction's commit is not locked out (a new
  appointment row has nothing to lock): it is caught by the *next* plan's
  recheck, which will see the new demand and the assignments that do not cover it.
  """

  use Ash.Resource.Change

  require Logger

  alias ClinicDemo.Planning
  alias ClinicDemo.Planning.{Machinery, Run, SnapshotBuilder}

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.before_action(&write(&1, context))
    |> Ash.Changeset.after_action(&attach_outcome/2)
    |> Ash.Changeset.after_transaction(&settle(&1, &2, context))
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: {:not_atomic, "apply writes other resources"}

  # ── inside the transaction ─────────────────────────────────────────────────

  defp write(changeset, context) do
    candidate = changeset.data

    with {:ok, run} <- Ash.get(Run, candidate.run_id, authorize?: false),
         {:ok, payload} <- SnapshotBuilder.problem_payload(run),
         {:ok, snapshot} <- SnapshotBuilder.snapshot_from_payload(payload),
         {:ok, model, _version} <- SnapshotBuilder.model_of(run),
         {:ok, current} <- model.current_inputs(payload),
         :ok <- recheck(snapshot, current),
         {:ok, outcome} <- model.apply_plan(candidate, payload, context.actor) do
      Ash.Changeset.set_context(changeset, %{planning_outcome: outcome})
    else
      {:drift, key} ->
        changeset
        |> Ash.Changeset.set_context(%{planning_apply: :drift})
        |> Ash.Changeset.add_error(
          field: :freshness,
          message: "a source changed since the snapshot (#{key}); the candidate is stale"
        )

      {:error, {:refused, error}} ->
        changeset
        |> Ash.Changeset.set_context(%{planning_apply: :refused})
        |> Ash.Changeset.add_error(
          field: :assignments,
          message: "apply refused: #{reason_text(error)}"
        )

      {:error, reason} ->
        changeset
        |> Ash.Changeset.set_context(%{planning_apply: :unreadable})
        |> Ash.Changeset.add_error(
          field: :assignments,
          message: "cannot apply: #{reason_text(reason)}"
        )
    end
  end

  # The snapshot's inputs against the inputs as they are now. `{:drift, key}` on
  # the first that differs (sorted, so the message is stable).
  defp recheck(snapshot, current_inputs) do
    then = Map.new(snapshot.inputs, &{{&1.key, &1.role}, &1.content_hash})
    now = Map.new(current_inputs, &{{&1.key, &1.role}, &1.content_hash})

    changed =
      then
      |> Map.keys()
      |> Enum.concat(Map.keys(now))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.find(&(Map.get(then, &1) != Map.get(now, &1)))

    case changed do
      nil -> :ok
      {key, _role} -> {:drift, key}
    end
  end

  defp attach_outcome(changeset, candidate) do
    case changeset.context[:planning_outcome] do
      nil -> {:ok, candidate}
      outcome -> {:ok, Ash.Resource.put_metadata(candidate, :planning_apply, outcome)}
    end
  end

  # ── after the transaction ──────────────────────────────────────────────────

  # The failure reason travels in the error text as well as the changeset context:
  # an error raised in `before_action` reaches this hook with the changeset as it
  # entered the action.
  defp settle(changeset, {:error, error} = result, context) do
    text = reason_text(error)

    reason =
      cond do
        text =~ "a source changed since the snapshot" -> :drift
        text =~ "apply refused" -> :refused
        true -> nil
      end

    if reason in [:drift, :refused], do: settle_refusal(changeset.data, context.actor)

    result
  end

  defp settle(_changeset, result, _context), do: result

  # A refused apply ends `:rejected` AND `:stale`, never an approved-looking stale
  # row. The freshness mark goes first (planner): `mark_stale` is only allowed on
  # an undecided or approved candidate.
  defp settle_refusal(candidate, actor) do
    with {:ok, stale} <- Planning.mark_candidate_stale(candidate, %{}, actor: Machinery.actor()),
         {:ok, _rejected} <- Planning.reject_candidate(stale, %{}, actor: actor) do
      :ok
    else
      {:error, error} -> Logger.error("planning apply settlement failed: #{reason_text(error)}")
    end
  end

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_text(%Ash.Changeset{errors: errors}),
    do: Enum.map_join(errors, "; ", &reason_text/1)

  defp reason_text(%{__exception__: true} = error), do: Exception.message(error)
  defp reason_text(_other), do: "refused"
end
