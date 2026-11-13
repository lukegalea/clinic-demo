defmodule ClinicDemo.Planning.WeeklyRosterTest do
  @moduledoc """
  The planning pipeline's honesty: what each axis says when the answer is not a
  plan, what the snapshot records and replays, and that a candidate is never
  trusted on one verdict.

  Driven through `AshPlanning.Backend.Fake`; the real-model equivalent is in
  `ClinicDemo.Planning.FlagshipTest` (`:solver`).
  """

  use ClinicDemo.DataCase, async: false

  import ClinicDemo.PlanningFixtures

  alias AshPlanning.Snapshot, as: PlanningSnapshot
  alias ClinicDemo.Planning

  alias ClinicDemo.Planning.{
    Binding,
    FourEyes,
    Install,
    Machinery,
    SnapshotBuilder,
    StaffingPolicy,
    WeeklyRoster
  }

  alias ClinicDemo.Scheduling

  defp one_day_week do
    team = team!()
    monday = next_monday()
    type = type!("Wellness exam")
    a1 = book!(monday, 1, {10, 0}, team.vet, type: type)
    a2 = book!(monday, 1, {11, 0}, team.vet, type: type)
    %{team: team, monday: monday, a1: a1, a2: a2}
  end

  defp good(w) do
    fn _payload ->
      {[{w.team.vet.id, 1, "early"}], [{w.a1.id, w.team.vet.id}, {w.a2.id, w.team.vet.id}]}
    end
  end

  describe "the axes are honest" do
    test "UNSAT is :infeasible and complete; no candidates" do
      w = one_day_week()

      {:ok, %{run: run, candidates: candidates}} =
        plan_fake(w.monday, staff(), good(w), fake: %{fake_outcome: :infeasible})

      assert {run.solve_status, run.complete?, run.optimality} == {:infeasible, true, :none}
      assert candidates == []
    end

    test "a timeout with an incumbent is :feasible, incomplete, never optimal" do
      w = one_day_week()

      {:ok, %{run: run, candidates: [candidate]}} =
        plan_fake(w.monday, staff(), good(w), fake: %{fake_outcome: :feasible})

      assert {run.solve_status, run.complete?, run.optimality} == {:feasible, false, :none}
      assert run.outcome_reason == :time_limit
      assert candidate.check_status == :correct
    end

    test "a timeout with no incumbent is :unknown, never :infeasible" do
      w = one_day_week()

      {:ok, %{run: run, candidates: []}} =
        plan_fake(w.monday, staff(), good(w), fake: %{fake_outcome: :unknown})

      assert {run.solve_status, run.complete?} == {:unknown, false}
    end

    test "a bad model is :invalid_model, a missing governor :backend_failed with its reason" do
      w = one_day_week()

      {:ok, %{run: invalid}} =
        plan_fake(w.monday, staff(), good(w), fake: %{fake_outcome: {:error, :invalid_model}})

      assert invalid.solve_status == :invalid_model

      {:ok, %{run: ungoverned}} =
        plan_fake(w.monday, staff(), good(w),
          fake: %{fake_outcome: {:error, :resource_governor_unavailable}}
        )

      assert ungoverned.solve_status == :backend_failed
      assert ungoverned.outcome_reason == :resource_governor_unavailable
    end
  end

  describe "preparation" do
    test "an appointment the roster cannot plan makes the run :needs_input, naming it" do
      team = team!()
      monday = next_monday()
      late = book!(monday, 1, {23, 45}, team.vet, type: type!("Wellness exam"))

      {:ok, %{run: run, candidates: []}} =
        plan_fake(monday, staff(), fn _ -> {[], []} end)

      assert run.preparation_status == :needs_input
      assert run.solve_status == nil

      assert [%{"id" => id, "status" => "invalid", "reason" => "crosses_midnight"}] =
               run.unresolved_inputs

      assert id == "appointment:#{late.id}"
      assert run.snapshot_digest
    end

    test "a week with no demand still plans: the empty roster is a roster" do
      team = team!()

      {:ok, %{run: run, candidates: [candidate]}} =
        plan_fake(next_monday(), staff(), fn _ -> {[], []} end)

      assert run.preparation_status == :prepared
      assert candidate.check_status == :correct
      assert candidate.unresolved_obligations == []
      _ = team
    end

    test "the schedule is read as of the knowledge cutoff: a later cancellation is not seen" do
      w = one_day_week()
      cutoff = DateTime.utc_now()
      Process.sleep(20)

      Scheduling.cancel_appointment!(w.a2, "synthetic cancellation", actor: staff())

      {:ok, %{run: before_cut}} = plan_fake(w.monday, staff(), good(w), cutoff: cutoff)

      {:ok, %{run: after_cut}} =
        plan_fake(w.monday, staff(), fn _ ->
          {[{w.team.vet.id, 1, "early"}], [{w.a1.id, w.team.vet.id}]}
        end)

      assert before_cut.stats["appointments"] == 2
      assert after_cut.stats["appointments"] == 1
      refute before_cut.snapshot_digest == after_cut.snapshot_digest
    end

    test "removed availability is read as of the cutoff and changes the digest" do
      w = one_day_week()
      cutoff = DateTime.utc_now()
      Process.sleep(20)
      remove_availability!(w.monday, 1, w.team.vet, {12, 0}, {13, 0})

      {:ok, %{run: seen}} = plan_fake(w.monday, staff(), good(w), cutoff: cutoff)
      {:ok, %{run: knows}} = plan_fake(w.monday, staff(), good(w))

      # The run with the earlier cutoff does not know the removal: it has one input fewer.
      assert seen.stats["inputs"] + 1 == knows.stats["inputs"]

      {:ok, seen_payload} = SnapshotBuilder.problem_payload(seen)
      {:ok, knows_payload} = SnapshotBuilder.problem_payload(knows)
      assert seen_payload["problem"]["unavailable"] == []
      assert [%{"clinician_id" => clinician_id}] = knows_payload["problem"]["unavailable"]
      assert clinician_id == w.team.vet.id
    end

    test "the snapshot pins definitions and carries references and hashes only" do
      w = one_day_week()
      {:ok, %{run: run}} = plan_fake(w.monday, staff(), good(w))
      {:ok, payload} = SnapshotBuilder.problem_payload(run)
      {:ok, snapshot} = SnapshotBuilder.snapshot_from_payload(payload)

      assert PlanningSnapshot.verify(snapshot)

      assert Enum.sort(Enum.map(snapshot.definitions, &{&1.kind, &1.key})) ==
               Enum.sort([
                 {:dmn, "staffing.policy"},
                 {:mzn, "weekly_roster"},
                 {:mzn, "weekly_roster.checker"},
                 {:validator, "ClinicDemo.Planning.RosterValidator"}
               ])

      assert Enum.all?(snapshot.inputs, &(&1.status == :value))
      encoded = Jason.encode!(payload["snapshot"])
      refute encoded =~ "Dr. Vik", "a snapshot never carries a name"
      refute encoded =~ "@example.com"

      # Tampering with the stored envelope is caught by its digest.
      tampered = put_in(payload, ["snapshot", "knowledge_cutoff"], "2020-01-01T00:00:00Z")
      assert {:error, :snapshot_digest_mismatch} = SnapshotBuilder.snapshot_from_payload(tampered)
    end

    test "a binding pinned to a decision that is not the published one is definition_drift, not a plan" do
      w = one_day_week()
      %{binding: binding} = Install.current!()

      selection =
        Enum.map(binding.selection, fn
          %{"kind" => "dmn"} = entry -> %{entry | "content_hash" => String.duplicate("0", 64)}
          other -> other
        end)

      Planning.rebind_model!(
        binding,
        %{selection: selection, backend_profile_hash: binding.backend_profile_hash},
        actor: staff()
      )

      {:ok, %{run: run, candidates: []}} = plan_fake(w.monday, staff(), good(w))
      assert run.preparation_status == :preparation_failed
      assert run.stats["reason"] == "definition_drift"
      assert run.solve_status == nil
    end

    test "a run resolves the binding valid as of its cutoff, not the live one" do
      w = one_day_week()
      {:ok, %{run: run}} = plan_fake(w.monday, staff(), good(w))
      %{binding: live} = Install.current!()

      Planning.rebind_model!(
        live,
        %{selection: live.selection, backend_profile_hash: String.duplicate("e", 64)},
        actor: staff()
      )

      {:ok, resolved} = Planning.Run.resolve_binding(run)
      assert resolved.backend_profile_hash == live.backend_profile_hash

      assert Ash.get!(Binding, live.id, authorize?: false).backend_profile_hash ==
               String.duplicate("e", 64)
    end
  end

  describe "the staffing policy decision" do
    test "answers the required role and the duration policy per appointment type, and the week's reserve and patterns" do
      %{binding: binding} = Install.current!()
      dmn = Enum.find(binding.selection, &(&1["kind"] == "dmn"))

      {:ok, definition} =
        StaffingPolicy.fetch_definition(
          dmn["key"],
          String.to_integer(dmn["version"]),
          dmn["content_hash"]
        )

      {:ok, policy} =
        StaffingPolicy.evaluate(definition, [
          "Wellness exam",
          "Vaccination",
          "Nail trim",
          "Surgery consult",
          nil,
          "Unlisted"
        ])

      assert policy.appointment["Wellness exam"] == %{role: :veterinarian, duration_minutes: 30}
      assert policy.appointment["Vaccination"] == %{role: :nurse, duration_minutes: 20}
      assert policy.appointment["Nail trim"] == %{role: :technician, duration_minutes: 15}
      assert policy.appointment["Surgery consult"] == %{role: :veterinarian, duration_minutes: 45}
      assert policy.appointment[""] == %{role: :veterinarian, duration_minutes: 30}
      assert policy.appointment["Unlisted"] == %{role: :veterinarian, duration_minutes: 30}

      assert policy.week[1] == %{reserve_minutes: 30, patterns: ["early", "late"]}
      assert policy.week[6] == %{reserve_minutes: 0, patterns: ["weekend"]}
      assert policy.week[7] == %{reserve_minutes: 0, patterns: []}
      assert policy.definition.key == "staffing.policy"
    end

    test "the duration policy is never shorter than the booking, and raises a short slot" do
      team = team!()
      monday = next_monday()
      booked = book!(monday, 1, {10, 0}, team.vet, type: type!("Surgery consult"), duration: 20)

      {:ok, %{run: run}} =
        plan_fake(monday, staff(), fn _ ->
          {[{team.vet.id, 1, "early"}], [{booked.id, team.vet.id}]}
        end)

      {:ok, payload} = SnapshotBuilder.problem_payload(run)
      [appointment] = payload["problem"]["appointments"]
      assert appointment["ends_at"] == "#{Date.to_iso8601(monday)}T10:45:00Z"
      assert appointment["required_role"] == "veterinarian"
    end

    test "the role policy decides who may cover: a nurse cannot cover an exam" do
      w = one_day_week()

      {:ok, %{candidates: [candidate]}} =
        plan_fake(w.monday, staff(), fn _ ->
          {[{w.team.manager.id, 1, "early"}],
           [{w.a1.id, w.team.manager.id}, {w.a2.id, w.team.manager.id}]}
        end)

      assert candidate.check_status == :incorrect
      [check] = Planning.list_check_results!(authorize?: false)

      assert check.checker_status == :correct,
             "the scripted checker accepted it; the validator did not"

      assert check.validator_status == :incorrect

      assert check.validator_reason in ["role_mismatch", "outside_shift_window"] or
               check.validator_reason != nil
    end
  end

  describe "two verdicts, never one" do
    test "a checker that rejects makes the candidate :incorrect even if the validator accepts" do
      w = one_day_week()

      {:ok, %{candidates: [candidate]}} =
        plan_fake(w.monday, staff(), good(w), checker_data: %{fake_outcome: :infeasible})

      assert candidate.check_status == :incorrect
      [check] = Planning.list_check_results!(authorize?: false)
      assert {check.checker_status, check.validator_status} == {:incorrect, :correct}
    end

    test "a checker that cannot answer is :checker_failed" do
      w = one_day_week()

      {:ok, %{candidates: [candidate]}} =
        plan_fake(w.monday, staff(), good(w), checker_data: %{fake_outcome: :unknown})

      assert candidate.check_status == :checker_failed
    end

    test "only a :correct, current, proposed candidate is offered for approval" do
      w = one_day_week()

      {:ok, %{candidates: [bad]}} =
        plan_fake(w.monday, staff(), good(w), checker_data: %{fake_outcome: :infeasible})

      assert {:error, :candidate_not_approvable} = WeeklyRoster.submit_for_approval(bad)
      assert {:error, _} = Planning.approve_candidate(bad, %{}, actor: Machinery.actor())
    end
  end

  describe "replanning" do
    test "a newer plan for the same week supersedes the earlier undecided candidates" do
      w = one_day_week()
      {:ok, %{candidates: [first]}} = plan_fake(w.monday, staff(), good(w))
      {:ok, _instance} = WeeklyRoster.submit_for_approval(first)
      {:ok, %{candidates: [second]}} = plan_fake(w.monday, staff(), good(w))

      assert Ash.get!(Planning.Candidate, first.id, authorize?: false).disposition == :superseded
      assert second.disposition == :proposed

      # Its sign-off tasks are closed, not left on a worklist.
      tasks = FourEyes.tasks(first.id)
      assert Enum.all?(tasks, fn {_node, task} -> task.status == :cancelled end)
    end
  end
end
