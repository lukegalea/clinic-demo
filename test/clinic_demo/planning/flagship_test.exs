defmodule ClinicDemo.Planning.FlagshipTest do
  @moduledoc """
  The clinic's weekly staffing flagship, as one scripted scenario:

      roster -> explain -> availability removed -> replan preserving what is
      applied and still assignable -> uncovered work exposed -> four-eyes approve
      -> concurrent booking -> stale apply refused

  The cast is a head vet, a second vet (on leave Monday), a nurse who is the clinic
  manager, and a technician; the week is next week. Five appointments are booked
  (two on Monday, two on Tuesday, one on Wednesday).

  Two runs of the same script:

    * the default one drives the pipeline through `AshPlanning.Backend.Fake` with
      scripted answers, so it needs no MiniZinc and runs in CI;
    * the `:solver` one solves the same weeks with the real model under Gecode and
      is skipped when `minizinc` is not on the PATH.

  Every candidate in both is held to the same bar: the MiniZinc solution checker
  AND the independent validator must each have said `correct` (two separate
  `CheckResult` columns), and the candidate is `:correct` only if both did.
  """

  use ClinicDemo.DataCase, async: false

  import ClinicDemo.PlanningFixtures

  require Ash.Query

  alias AshOpenLineage.Snapshot
  alias AshPlanning.Snapshot, as: PlanningSnapshot
  alias ClinicDemo.BusinessEvents
  alias ClinicDemo.BusinessEvents.Ledger
  alias ClinicDemo.Planning
  alias ClinicDemo.Planning.{FourEyes, SnapshotBuilder, WeeklyRoster}
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Visits.Instance

  setup do
    BusinessEvents.install!()
    :ok
  end

  # ── the cast and the demand ────────────────────────────────────────────────

  defp cast do
    team = team!()
    monday = next_monday()
    wellness = type!("Wellness exam")
    vaccination = type!("Vaccination")
    trim = type!("Nail trim")

    # The second vet is on leave all Monday: Monday is the head vet's day alone.
    remove_availability!(monday, 1, team.vet, {0, 0}, {23, 59}, "course")

    a1 = book!(monday, 1, {10, 0}, team.head_vet, type: wellness)
    a2 = book!(monday, 1, {11, 0}, team.head_vet, type: wellness)
    a3 = book!(monday, 2, {10, 0}, team.vet, type: wellness)
    a4 = book!(monday, 2, {14, 0}, team.manager, type: vaccination, duration: 20)
    a5 = book!(monday, 3, {9, 0}, team.tech, type: trim, duration: 15)

    Map.merge(team, %{monday: monday, appts: [a1, a2, a3, a4, a5]})
  end

  # The scripted backend answers. Shifts are `{clinician, iso_day, pattern}`.
  defp script_v1(cast) do
    [a1, a2, a3, a4, a5] = cast.appts

    fn _payload ->
      {[
         {cast.head_vet.id, 1, "early"},
         {cast.vet.id, 2, "early"},
         {cast.manager.id, 2, "late"},
         {cast.tech.id, 3, "early"}
       ],
       [
         {a1.id, cast.head_vet.id},
         {a2.id, cast.head_vet.id},
         {a3.id, cast.vet.id},
         {a4.id, cast.manager.id},
         {a5.id, cast.tech.id}
       ]}
    end
  end

  # After Monday's availability is removed, the head vet's Monday shift and the two
  # Monday visits are gone from the answer; everything else is exactly as applied.
  defp script_v2(cast) do
    [_a1, _a2, a3, a4, a5] = cast.appts

    fn _payload ->
      {[
         {cast.vet.id, 2, "early"},
         {cast.manager.id, 2, "late"},
         {cast.tech.id, 3, "early"}
       ], [{a3.id, cast.vet.id}, {a4.id, cast.manager.id}, {a5.id, cast.tech.id}]}
    end
  end

  defp plan_scripted(cast, script) do
    plan_fake(cast.monday, staff(), script)
  end

  # ── the script ─────────────────────────────────────────────────────────────

  test "roster, explain, replan, expose, four-eyes approve, concurrent booking, stale refused" do
    cast = cast()
    [a1, a2, a3, a4, a5] = cast.appts

    # 1. Generate next week's roster. ----------------------------------------
    {:ok, %{run: run1, candidates: [v1]}} = plan_scripted(cast, script_v1(cast))

    assert run1.preparation_status == :prepared
    assert run1.solve_status == :optimal
    assert run1.knowledge_cutoff
    assert v1.check_status == :correct
    assert v1.freshness == :current
    assert v1.disposition == :proposed
    assert v1.unresolved_obligations == []

    # The snapshot is sealed, replayable and pins the staffing decision and the model.
    {:ok, payload} = SnapshotBuilder.problem_payload(run1)
    {:ok, snapshot} = SnapshotBuilder.snapshot_from_payload(payload)
    assert PlanningSnapshot.verify(snapshot)
    assert snapshot.digest == run1.snapshot_digest
    assert snapshot.purpose == :"planning.weekly_roster"
    assert %Snapshot.Definition{} = PlanningSnapshot.definition(snapshot, :dmn, "staffing.policy")
    assert PlanningSnapshot.definition(snapshot, :mzn, "weekly_roster")

    # Both verdicts were recorded separately for the candidate.
    [check] = Planning.list_check_results!(authorize?: false)
    assert {check.checker_status, check.validator_status} == {:correct, :correct}

    # Nothing has changed on the schedule: a candidate is inert.
    assert Scheduling.list_shifts!(authorize?: false) == []
    assert Scheduling.list_assignments!(authorize?: false) == []

    # 2. Explain the assignments. --------------------------------------------
    {:ok, explanations} = WeeklyRoster.explain(v1)
    assert length(explanations) == 5
    assert Enum.all?(explanations, & &1.covered?)
    first = Enum.find(explanations, &(&1.appointment_id == a1.id))
    assert first.clinician_id == cast.head_vet.id
    assert :required_role_held in first.reasons
    assert :booked_clinician in first.reasons
    refute :preserved_from_applied_plan in first.reasons

    # The baseline is approved by the clinic manager AND the head vet, and applied.
    {:ok, applied} = approve_and_apply(v1, cast)
    assert applied.disposition == :applied

    assert applied.__metadata__[:planning_apply]
           |> Map.take([:placed_shifts, :placed_assignments, :preserved_assignments]) ==
             %{placed_shifts: 4, placed_assignments: 5, preserved_assignments: 0}

    assert length(Scheduling.list_shifts!(authorize?: false)) == 4
    assert length(Scheduling.list_assignments!(authorize?: false)) == 5

    # Every appointment kept its single visit process: an assignment is not a
    # second way to start one.
    for appointment <- cast.appts do
      assert Instance
             |> Ash.Query.filter(subject_id == ^appointment.id)
             |> Ash.count!(authorize?: false) == 1
    end

    # 3. Remove one clinician's availability. -------------------------------
    remove_availability!(cast.monday, 1, cast.head_vet, {0, 0}, {23, 59}, "leave")

    # 4. Replan, preserving every applied assignment that remains feasible. ---
    {:ok, %{run: run2, candidates: [v2]}} = plan_scripted(cast, script_v2(cast))

    assert run2.preparation_status == :prepared
    assert v2.check_status == :correct

    # The replan read what was applied: the applied plan is part of its snapshot.
    {:ok, payload2} = SnapshotBuilder.problem_payload(run2)
    assert length(payload2["problem"]["previous"]["shifts"]) == 4
    assert length(payload2["problem"]["previous"]["assignments"]) == 5
    refute run2.snapshot_digest == run1.snapshot_digest

    {:ok, plan2} = Jason.decode(v2.assignments)
    assert plan2["preserved_assignments"] == 3
    assert plan2["previous_assignments"] == 5

    # 5. Uncovered work is exposed, with a reason, never silently dropped. ----
    assert Enum.sort(Enum.map(v2.unresolved_obligations, & &1["id"])) == Enum.sort([a1.id, a2.id])
    assert Enum.all?(v2.unresolved_obligations, &(&1["reason"] == "uncovered"))

    {:ok, explained} = WeeklyRoster.explain(v2)
    uncovered = Enum.reject(explained, & &1.covered?)
    assert Enum.sort(Enum.map(uncovered, & &1.appointment_id)) == Enum.sort([a1.id, a2.id])
    assert Enum.all?(uncovered, &(&1.reasons == [:all_qualified_unavailable]))
    kept = Enum.find(explained, &(&1.appointment_id == a3.id))
    assert :preserved_from_applied_plan in kept.reasons

    # The earlier candidate was already applied; nothing else for the week is open.
    assert Planning.list_candidates!(authorize?: false)
           |> Enum.count(&(&1.disposition == :proposed)) == 1

    # 6. Four-eyes approve and apply the replan. ------------------------------
    {:ok, applied2} = approve_and_apply(v2, cast)
    assert applied2.disposition == :applied

    assert Map.take(applied2.__metadata__[:planning_apply], [
             :cancelled_assignments,
             :cancelled_shifts,
             :preserved_assignments,
             :preserved_shifts,
             :placed_shifts,
             :placed_assignments
           ]) == %{
             cancelled_assignments: 2,
             cancelled_shifts: 1,
             preserved_assignments: 3,
             preserved_shifts: 3,
             placed_shifts: 0,
             placed_assignments: 0
           }

    scheduled = fn module ->
      module |> Ash.Query.filter(state == :scheduled) |> Ash.read!(authorize?: false)
    end

    assert length(scheduled.(ClinicDemo.Scheduling.Shift)) == 3

    assert Enum.sort(Enum.map(scheduled.(ClinicDemo.Scheduling.Assignment), & &1.appointment_id)) ==
             Enum.sort([a3.id, a4.id, a5.id])

    # The two cancelled rows are history, not deletions.
    assert length(Scheduling.list_assignments!(authorize?: false)) == 5

    # 7. Plan once more; a booking lands while the plan awaits its second signature.
    {:ok, %{candidates: [v3]}} = plan_scripted(cast, script_v2(cast))
    assert v3.check_status == :correct
    {:ok, _instance} = WeeklyRoster.submit_for_approval(v3)
    tasks = FourEyes.tasks(v3.id)

    assert {:ok, still_proposed} =
             FourEyes.sign(tasks["ManagerSignoff"].id, :approved, as(cast.manager))

    assert still_proposed.disposition == :proposed, "one signature approves nothing"

    _concurrent = book!(cast.monday, 4, {10, 0}, cast.vet, type: type!("Wellness exam"))

    # 8. The stale apply is refused, and leaves no trace on the schedule. ------
    shifts_before = Scheduling.list_shifts!(authorize?: false)
    assignments_before = Scheduling.list_assignments!(authorize?: false)

    assert {:error, error} =
             FourEyes.sign(tasks["HeadVetSignoff"].id, :approved, as(cast.head_vet))

    assert Exception.message(error) =~ "a source changed since the snapshot"

    refused = Ash.get!(Planning.Candidate, v3.id, authorize?: false)
    assert refused.disposition == :rejected
    assert refused.freshness == :stale

    assert Scheduling.list_shifts!(authorize?: false) == shifts_before
    assert Scheduling.list_assignments!(authorize?: false) == assignments_before

    # A stale candidate can never be applied afterwards, by anyone.
    assert {:error, _} = Planning.apply_candidate(refused, %{}, actor: as(cast.head_vet))
  end

  test "a candidate is evaluated on the simulation twin and the real ledger never notices" do
    cast = cast()
    {:ok, %{run: run, candidates: [candidate]}} = plan_scripted(cast, script_v1(cast))

    real_before = length(Ledger.by_region!(:clinic))

    result = WeeklyRoster.simulate(candidate, multiplier: Decimal.new("99"))

    assert result.simulated?
    assert result.identity.candidate_id == candidate.id
    assert result.identity.snapshot_digest == run.snapshot_digest

    assert result.identity.model_hash ==
             Ash.get!(Planning.ModelVersion, run.model_version_id, authorize?: false).model_sha256

    assert String.starts_with?(result.run, "scenario:plan-")

    # The simulated events are in the twin, with the five-tuple in their context.
    twin =
      Ledger.SimulationEvent
      |> Ash.Query.filter(simulation_run == ^result.run)
      |> Ash.read!(authorize?: false)

    assert twin != []
    assert Enum.all?(twin, &(&1.context["evaluation"]["candidate_id"] == candidate.id))
    assert length(Ledger.by_region!(:clinic)) == real_before

    # Same identity again: nothing new. Another replication: another run.
    assert WeeklyRoster.simulate(candidate, multiplier: Decimal.new("99")).appended == 0
    other = WeeklyRoster.simulate(candidate, multiplier: Decimal.new("99"), replication_id: 1)
    refute other.run == result.run
  end

  @tag :solver
  test "the same weeks solved by the real model: both checks on every candidate, preserved and exposed" do
    cast = cast()
    [a1, a2, a3, a4, a5] = cast.appts
    real = [actor: staff()]

    {:ok, %{run: run1, candidates: [v1 | _]}} =
      WeeklyRoster.plan([week_start: cast.monday] ++ real)

    assert run1.solve_status in [:optimal, :feasible]

    assert Enum.all?(
             Planning.list_check_results!(authorize?: false),
             &({&1.checker_status, &1.validator_status} == {:correct, :correct})
           )

    assert v1.check_status == :correct
    assert v1.unresolved_obligations == []

    {:ok, applied} = approve_and_apply(v1, cast)
    assert applied.disposition == :applied
    assert length(Scheduling.list_assignments!(authorize?: false)) == 5

    remove_availability!(cast.monday, 1, cast.head_vet, {0, 0}, {23, 59}, "leave")

    {:ok, %{candidates: [v2 | _]}} = WeeklyRoster.plan([week_start: cast.monday] ++ real)
    assert v2.check_status == :correct

    {:ok, plan2} = Jason.decode(v2.assignments)
    assert plan2["preserved_assignments"] == 3
    assert Enum.sort(Enum.map(v2.unresolved_obligations, & &1["id"])) == Enum.sort([a1.id, a2.id])

    kept =
      Enum.map(plan2["assignments"], &{&1["appointment_id"], &1["clinician_id"]}) |> Enum.sort()

    assert kept ==
             Enum.sort([{a3.id, cast.vet.id}, {a4.id, cast.manager.id}, {a5.id, cast.tech.id}])

    {:ok, applied2} = approve_and_apply(v2, cast)
    assert applied2.__metadata__[:planning_apply].preserved_assignments == 3
  end

  # Two different approvers, each as themselves; the second signature applies.
  defp approve_and_apply(candidate, cast) do
    {:ok, _instance} = WeeklyRoster.submit_for_approval(candidate)
    tasks = FourEyes.tasks(candidate.id)

    {:ok, _} = FourEyes.sign(tasks["ManagerSignoff"].id, :approved, as(cast.manager))
    FourEyes.sign(tasks["HeadVetSignoff"].id, :approved, as(cast.head_vet))
  end

  defp as(clinician), do: %{id: clinician.id}
end
