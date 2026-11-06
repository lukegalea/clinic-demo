defmodule ClinicDemo.Planning.Changes.ApplyCandidate do
  @moduledoc """
  The host side of `Candidate.apply`: a person commits an approved, checked
  candidate by writing `Shift` and `Assignment` rows through their own actions,
  after a freshness recheck.

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
       reader that built them; any input that was added, removed or whose content
       hash moved (a booking, a rescheduled or cancelled appointment, a changed
       availability, a shift applied by another candidate) is *drift* and refuses
       the apply. Nothing is written.
    2. **Diff against what is applied.** The candidate is a whole-week plan. Shifts
       and assignments the week already has and the plan keeps are left alone (and
       counted as preserved); ones the plan drops are cancelled; new ones are
       placed.
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
  (`record.__metadata__[:planning_apply]`: `placed_shifts`, `placed_assignments`,
  `cancelled_shifts`, `cancelled_assignments`, `preserved_shifts`,
  `preserved_assignments`).

  The recheck and the writes share one transaction, but a booking that commits
  between the recheck and this transaction's commit is not locked out (a new
  appointment row has nothing to lock): it is caught by the *next* plan's
  recheck, which will see the new demand and the assignments that do not cover it.
  """

  use Ash.Resource.Change

  require Logger

  alias ClinicDemo.Planning
  alias ClinicDemo.Planning.Checks.AppliedByCandidate
  alias ClinicDemo.Planning.{Machinery, Reader, Run, SnapshotBuilder}
  alias ClinicDemo.Scheduling

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
         {:ok, week_start} <- Date.from_iso8601(payload["problem"]["week_start"]),
         facts = Reader.read(week_start, DateTime.utc_now()),
         :ok <- recheck(snapshot, facts),
         {:ok, plan} <- plan(candidate) do
      transact(changeset, candidate, plan, facts, context.actor)
    else
      {:drift, key} ->
        changeset
        |> Ash.Changeset.set_context(%{planning_apply: :drift})
        |> Ash.Changeset.add_error(
          field: :freshness,
          message: "a source changed since the snapshot (#{key}); the candidate is stale"
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
  defp recheck(snapshot, facts) do
    then = Map.new(snapshot.inputs, &{{&1.key, &1.role}, &1.content_hash})
    now = Map.new(Reader.inputs(facts), &{{&1.key, &1.role}, &1.content_hash})

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

  defp plan(candidate) do
    with binary when is_binary(binary) <- candidate.assignments,
         {:ok, %{"shifts" => shifts, "assignments" => assignments}} <- Jason.decode(binary) do
      {:ok, %{shifts: Enum.map(shifts, &parse_shift/1), assignments: assignments}}
    else
      _ -> {:error, :assignments_unreadable}
    end
  end

  defp parse_shift(shift) do
    {:ok, starts_at, _} = DateTime.from_iso8601(shift["starts_at"])
    {:ok, ends_at, _} = DateTime.from_iso8601(shift["ends_at"])
    %{shift | "starts_at" => starts_at, "ends_at" => ends_at}
  end

  defp transact(changeset, candidate, plan, facts, actor) do
    opts = [actor: actor]

    shift_key = &{&1.clinician_id, &1.starts_at, &1.ends_at}
    planned_shift_key = &{&1["clinician_id"], &1["starts_at"], &1["ends_at"]}
    assignment_key = &{&1.appointment_id, &1.clinician_id}
    planned_assignment_key = &{&1["appointment_id"], &1["clinician_id"]}

    {keep_shifts, drop_shifts} = split(facts.shifts, shift_key, plan.shifts, planned_shift_key)

    {keep_assignments, drop_assignments} =
      split(facts.assignments, assignment_key, plan.assignments, planned_assignment_key)

    kept_shift_keys = MapSet.new(keep_shifts, shift_key)
    kept_assignment_keys = MapSet.new(keep_assignments, assignment_key)

    place_shifts =
      Enum.reject(plan.shifts, &MapSet.member?(kept_shift_keys, planned_shift_key.(&1)))

    place_assignments =
      Enum.reject(
        plan.assignments,
        &MapSet.member?(kept_assignment_keys, planned_assignment_key.(&1))
      )

    steps =
      Enum.map(drop_assignments, &{:cancel_assignment, &1}) ++
        Enum.map(drop_shifts, &{:cancel_shift, &1}) ++
        Enum.map(place_shifts, &{:place_shift, &1}) ++
        Enum.map(place_assignments, &{:place_assignment, &1})

    # We are already inside the apply action's transaction: every write below
    # joins it, and returning the error from this hook rolls all of them back
    # together.
    result =
      AppliedByCandidate.with_marker(
        candidate.id,
        MapSet.new(Enum.map(drop_assignments ++ drop_shifts, & &1.id)),
        fn ->
          Enum.reduce_while(steps, :ok, fn step, :ok ->
            case run_step(step, candidate.id, opts) do
              :ok -> {:cont, :ok}
              {:error, error} -> {:halt, {:error, error}}
            end
          end)
        end
      )

    case result do
      :ok ->
        outcome = %{
          placed_shifts: length(place_shifts),
          placed_assignments: length(place_assignments),
          cancelled_shifts: length(drop_shifts),
          cancelled_assignments: length(drop_assignments),
          preserved_shifts: length(keep_shifts),
          preserved_assignments: length(keep_assignments)
        }

        Ash.Changeset.set_context(changeset, %{planning_outcome: outcome})

      {:error, error} ->
        changeset
        |> Ash.Changeset.set_context(%{planning_apply: :refused})
        |> Ash.Changeset.add_error(
          field: :assignments,
          message: "apply refused: #{reason_text(error)}"
        )
    end
  end

  # {applied rows the plan keeps, applied rows the plan drops}
  defp split(applied, applied_key, planned, planned_key) do
    planned_keys = MapSet.new(planned, planned_key)
    Enum.split_with(applied, &MapSet.member?(planned_keys, applied_key.(&1)))
  end

  defp run_step({:cancel_assignment, row}, _candidate_id, opts),
    do: ok(Scheduling.cancel_assignment(row.id, %{}, opts))

  defp run_step({:cancel_shift, row}, _candidate_id, opts),
    do: ok(Scheduling.cancel_shift(row.id, %{}, opts))

  defp run_step({:place_shift, shift}, candidate_id, opts) do
    ok(
      Scheduling.place_shift(
        %{
          role: shift["role"],
          starts_at: shift["starts_at"],
          ends_at: shift["ends_at"],
          candidate_id: candidate_id,
          clinician_id: shift["clinician_id"],
          shift_template_id: shift["shift_template_id"]
        },
        opts
      )
    )
  end

  defp run_step({:place_assignment, assignment}, candidate_id, opts) do
    ok(
      Scheduling.place_assignment(
        %{
          appointment_id: assignment["appointment_id"],
          role: assignment["role"],
          candidate_id: candidate_id,
          clinician_id: assignment["clinician_id"]
        },
        opts
      )
    )
  end

  defp ok({:ok, _record}), do: :ok
  defp ok({:error, error}), do: {:error, error}

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
