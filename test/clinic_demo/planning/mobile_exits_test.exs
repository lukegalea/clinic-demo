defmodule ClinicDemo.Planning.MobileExitsTest do
  @moduledoc """
  The three programme exits of Phase 5 (clinic mobile veterinary visits), each proven
  twice: once through `AshPlanning.Backend.Fake` with scripted answers (needs no
  MiniZinc; runs in CI) and once with the real model under Gecode (`:solver`, skipped
  when `minizinc` is not on the PATH).

    1. **Travel against a commitment is refused.** A mobile visit that fits its
       requested window is refused because the travel it needs conflicts with an
       in-clinic commitment: the run is proven `:infeasible`, no candidate exists, and
       the diagnosis names the commitment. It is never squeezed in.
    2. **A replan after a cancellation preserves pinned in-clinic work.** One visit is
       cancelled after the route was applied; the replan updates the route, keeps the
       other visits where they were and never touches the in-clinic appointments.
    3. **The travel matrix hash is in the snapshot.** The matrix artifact is a snapshot
       input (role `:travel_matrix`) carrying its content hash; changing the matrix
       changes the snapshot digest.

  The cast: a veterinarian with a kit, the clinic and three farms on an invented map
  (`ClinicDemo.MobileFixtures`), and next Monday.
  """

  use ClinicDemo.DataCase, async: false

  import ClinicDemo.MobileFixtures
  import ClinicDemo.PlanningFixtures, only: [staff: 0, next_monday: 0, team!: 0]

  alias AshOpenLineage.Snapshot
  alias AshPlanning.Snapshot, as: PlanningSnapshot
  alias ClinicDemo.BusinessEvents
  alias ClinicDemo.Planning
  alias ClinicDemo.Planning.{FourEyes, MobileVisits, SnapshotBuilder}
  alias ClinicDemo.Scheduling

  setup do
    BusinessEvents.install!()
    :ok
  end

  # ── the cast ───────────────────────────────────────────────────────────────

  defp cast do
    team = team!()
    vet = team.vet
    places = places!()
    matrix = publish_matrix!(places)
    Map.merge(team, %{places: places, matrix: matrix, monday: next_monday(), mobile_vet: vet})
  end

  # ── exit 1: travel against a commitment is refused ─────────────────────────

  describe "exit 1 - a visit that fits its window is refused because its travel conflicts with an in-clinic commitment" do
    # The vet sees a patient in the clinic 10:00-10:30. Farm A is 20 minutes from the
    # clinic. The visit's window is 10:35-11:05 and it takes 30 minutes: it fits the
    # window (10:35 start, 11:05 end) and the calendar is free from 10:30, but the
    # drive from the clinic needs until 10:50.
    defp refused_cast do
      cast = cast()
      commitment = in_clinic!(cast.monday, {10, 0}, cast.mobile_vet)
      visit = request_visit!(cast.monday, {10, 35}, {11, 5}, cast.places.a)
      Map.merge(cast, %{commitment: commitment, visit: visit})
    end

    test "scripted: the run is :infeasible and complete, with no candidate, and the diagnosis names the commitment" do
      cast = refused_cast()

      {:ok, %{run: run, candidates: candidates}} =
        plan_fake(cast.monday, cast.mobile_vet, staff(), %{}, fake: %{fake_outcome: :infeasible})

      assert run.preparation_status == :prepared
      assert {run.solve_status, run.complete?, run.optimality} == {:infeasible, true, :none}
      assert candidates == []

      assert [%{visit_request_id: visit_id, reason: :travel_conflict, blocking: [blocking]}] =
               MobileVisits.refusals(run)

      assert visit_id == cast.visit.id
      assert blocking == cast.commitment.id
    end

    @tag :solver
    test "solver: the model proves it infeasible; cancelling the commitment makes the same visit plannable" do
      cast = refused_cast()

      {:ok, %{run: run, candidates: candidates}} =
        MobileVisits.plan(day: cast.monday, clinician_id: cast.mobile_vet.id, actor: staff())

      assert run.preparation_status == :prepared
      assert {run.solve_status, run.complete?} == {:infeasible, true}
      assert candidates == []

      assert [%{reason: :travel_conflict, blocking: [blocking]}] = MobileVisits.refusals(run)
      assert blocking == cast.commitment.id

      # Without the in-clinic commitment the very same request has room for its drive.
      Scheduling.cancel_appointment!(cast.commitment, "synthetic cancellation", actor: staff())

      {:ok, %{run: run2, candidates: [candidate | _]}} =
        MobileVisits.plan(day: cast.monday, clinician_id: cast.mobile_vet.id, actor: staff())

      assert run2.solve_status == :optimal
      assert candidate.check_status == :correct
      assert [%{"starts_at" => starts_at}] = decoded(candidate)["stops"]
      {:ok, starts_at, _} = DateTime.from_iso8601(starts_at)
      assert starts_at == DateTime.new!(cast.monday, ~T[10:35:00], "Etc/UTC")
    end
  end

  # ── exit 2: a replan after a cancellation preserves pinned in-clinic work ───

  describe "exit 2 - a replan after one visit is cancelled updates the route and preserves pinned in-clinic work" do
    # In-clinic: 09:00-09:30 and 14:00-14:30. Three mobile visits: farm A (window
    # 10:00-12:00), farm B (10:00-13:00, a gate: +5 minutes) and farm C (15:00-17:00).
    defp replan_cast do
      cast = cast()

      morning = in_clinic!(cast.monday, {9, 0}, cast.mobile_vet)
      afternoon = in_clinic!(cast.monday, {14, 0}, cast.mobile_vet)

      a = request_visit!(cast.monday, {10, 0}, {12, 0}, cast.places.a)
      b = request_visit!(cast.monday, {10, 0}, {13, 0}, cast.places.b)
      c = request_visit!(cast.monday, {15, 0}, {17, 0}, cast.places.c)

      Map.merge(cast, %{in_clinic: [morning, afternoon], visits: %{a: a, b: b, c: c}})
    end

    # Scripted starts that satisfy both verdicts for the cast above.
    defp starts_v1(cast) do
      %{cast.visits.a.id => {10, 0}, cast.visits.b.id => {11, 0}, cast.visits.c.id => {15, 30}}
    end

    defp starts_v2(cast), do: Map.delete(starts_v1(cast), cast.visits.b.id)

    defp in_clinic_snapshot(cast) do
      for appointment <- cast.in_clinic do
        current = Scheduling.get_appointment!(appointment.id, authorize?: false)
        {current.id, current.scheduled_at, current.status, current.location_mode}
      end
    end

    defp route(candidate) do
      [first | _] = legs = decoded(candidate)["legs"]
      [first["from"] | Enum.map(legs, & &1["to"])]
    end

    defp replan_exit(cast, plan) do
      before_clinic = in_clinic_snapshot(cast)
      assert Enum.all?(before_clinic, &(elem(&1, 3) == :in_clinic))

      {:ok, %{run: run1, candidates: [v1 | _]}} = plan.(1)
      assert v1.check_status == :correct
      assert run1.solve_status in [:optimal, :feasible]

      # The plan places all three visits around both commitments.
      plan1 = decoded(v1)
      assert length(plan1["stops"]) == 3
      assert plan1["preserved_visits"] == 0

      commitment_labels = Enum.map(cast.in_clinic, &"appointment:#{&1.id}")
      assert Enum.all?(commitment_labels, &(&1 in route(v1))), "pinned work is in the route"

      # Nothing on the schedule changed: a candidate is inert.
      assert mobile_appointments() == []

      {:ok, applied} = approve_and_apply(v1, cast)
      assert applied.disposition == :applied

      assert Map.take(applied.__metadata__[:planning_apply], [
               :booked_visits,
               :moved_visits,
               :preserved_visits
             ]) == %{booked_visits: 3, moved_visits: 0, preserved_visits: 0}

      booked = mobile_appointments()
      assert length(booked) == 3
      assert Enum.all?(booked, &(&1.clinician_id == cast.mobile_vet.id))

      assert Enum.all?(
               Map.values(cast.visits),
               &(Scheduling.get_visit_request!(&1.id).state == :scheduled)
             )

      # One visit is cancelled: its request and its booked appointment both end.
      b_label = "visit_request:#{cast.visits.b.id}"
      assert b_label in route(v1)
      Scheduling.cancel_visit_request!(cast.visits.b.id, "owner called it off", actor: staff())
      assert length(mobile_appointments()) == 2

      # The replan reads what was applied and what was cancelled.
      {:ok, %{run: run2, candidates: [v2 | _]}} = plan.(2)
      assert run2.preparation_status == :prepared
      assert v2.check_status == :correct
      refute run2.snapshot_digest == run1.snapshot_digest

      {:ok, payload2} = SnapshotBuilder.problem_payload(run2)
      assert length(payload2["problem"]["visits"]) == 2
      assert Enum.all?(payload2["problem"]["visits"], & &1["previous_starts_at"])

      plan2 = decoded(v2)

      # The route is updated: the cancelled visit is gone, the pinned work is not.
      assert Enum.map(plan2["stops"], & &1["visit_request_id"]) |> Enum.sort() ==
               Enum.sort([cast.visits.a.id, cast.visits.c.id])

      refute b_label in route(v2)
      assert Enum.all?(commitment_labels, &(&1 in route(v2)))
      assert route(v2) == List.delete(route(v1), b_label)
      assert length(plan2["legs"]) == length(plan1["legs"]) - 1

      # The two visits that remain keep their booked start; nothing else moved.
      assert plan2["previous_visits"] == 2
      assert plan2["preserved_visits"] == 2
      assert plan2["moved_visits"] == 0

      {:ok, applied2} = approve_and_apply(v2, cast)
      assert applied2.disposition == :applied

      assert Map.take(applied2.__metadata__[:planning_apply], [
               :booked_visits,
               :moved_visits,
               :preserved_visits
             ]) == %{booked_visits: 0, moved_visits: 0, preserved_visits: 2}

      # The pinned in-clinic work was never touched by either plan.
      assert in_clinic_snapshot(cast) == before_clinic
      assert length(mobile_appointments()) == 2
    end

    test "scripted: the cancelled visit leaves the route, the others keep their start, in-clinic work is untouched" do
      cast = replan_cast()

      replan_exit(cast, fn
        1 -> plan_fake(cast.monday, cast.mobile_vet, staff(), starts_v1(cast))
        2 -> plan_fake(cast.monday, cast.mobile_vet, staff(), starts_v2(cast))
      end)
    end

    @tag :solver
    test "solver: the same, with the real model and both verdicts on every candidate" do
      cast = replan_cast()

      replan_exit(cast, fn _round ->
        MobileVisits.plan(day: cast.monday, clinician_id: cast.mobile_vet.id, actor: staff())
      end)

      assert Enum.all?(
               Planning.list_check_results!(authorize?: false),
               &({&1.checker_status, &1.validator_status} == {:correct, :correct})
             )
    end
  end

  defp mobile_appointments do
    Scheduling.list_appointments!(authorize?: false)
    |> Enum.filter(&(&1.location_mode == :mobile and &1.status == :scheduled))
  end

  # Two different approvers, each as themselves; the second signature applies.
  defp approve_and_apply(candidate, cast) do
    {:ok, _instance} = MobileVisits.submit_for_approval(candidate)
    tasks = FourEyes.tasks(candidate.id)

    {:ok, _} = FourEyes.sign(tasks["ManagerSignoff"].id, :approved, as(cast.manager))
    FourEyes.sign(tasks["HeadVetSignoff"].id, :approved, as(cast.head_vet))
  end

  defp as(clinician), do: %{id: clinician.id}

  # ── exit 3: the matrix hash is in the snapshot ─────────────────────────────

  describe "exit 3 - the travel matrix artifact hash is in the snapshot; changing it changes the digest" do
    defp one_visit_cast do
      cast = cast()
      visit = request_visit!(cast.monday, {9, 0}, {12, 0}, cast.places.a)
      Map.put(cast, :visit, visit)
    end

    defp plan_one(cast, opts \\ []) do
      plan_fake(cast.monday, cast.mobile_vet, staff(), %{cast.visit.id => {9, 0}}, opts)
    end

    defp snapshot_of(run) do
      {:ok, payload} = SnapshotBuilder.problem_payload(run)
      {:ok, snapshot} = SnapshotBuilder.snapshot_from_payload(payload)
      snapshot
    end

    defp matrix_input(snapshot) do
      Enum.find(snapshot.inputs, &(&1.role == :travel_matrix))
    end

    test "the snapshot carries the matrix as an input with its content hash, and the digest verifies" do
      cast = one_visit_cast()
      {:ok, %{run: run}} = plan_one(cast)
      snapshot = snapshot_of(run)

      assert snapshot.purpose == :"planning.mobile_visits"
      assert PlanningSnapshot.verify(snapshot)
      assert snapshot.digest == run.snapshot_digest

      assert %Snapshot.Input{
               key: "travel_matrix:clinic_van",
               role: :travel_matrix,
               status: :value,
               content_hash: hash,
               source: %{id: id, version_number: 1}
             } = matrix_input(snapshot)

      assert hash == cast.matrix.content_hash
      assert id == cast.matrix.id

      # The model, its checker and the independent validator are pinned too.
      assert Enum.sort(Enum.map(snapshot.definitions, &{&1.kind, &1.key})) ==
               Enum.sort([
                 {:mzn, "mobile_visits"},
                 {:mzn, "mobile_visits.checker"},
                 {:validator, "ClinicDemo.Planning.MobileValidator"}
               ])
    end

    test "a new matrix version is a different input hash and a different digest; the rest of the snapshot is the same" do
      cast = one_visit_cast()
      cutoff = DateTime.utc_now()
      Process.sleep(20)

      {:ok, %{run: before}} = plan_one(cast, cutoff: cutoff)

      v2 = publish_matrix!(cast.places, "clinic_van", %{{:clinic, :a} => 25})
      refute v2.content_hash == cast.matrix.content_hash

      {:ok, %{run: later}} = plan_one(cast)
      {:ok, %{run: replay}} = plan_one(cast, cutoff: cutoff)

      before_snapshot = snapshot_of(before)
      later_snapshot = snapshot_of(later)

      # Only the matrix input moved between the two plans.
      moved =
        for input <- later_snapshot.inputs,
            old =
              Enum.find(before_snapshot.inputs, &(&1.key == input.key and &1.role == input.role)),
            old.content_hash != input.content_hash,
            do: input.key

      assert moved == ["travel_matrix:clinic_van"]
      assert matrix_input(later_snapshot).content_hash == v2.content_hash
      assert matrix_input(later_snapshot).source.version_number == 2
      refute later.snapshot_digest == before.snapshot_digest

      # The matrix is read as of the knowledge cutoff: a replay before version 2 was
      # published sees version 1 again, input for input.
      replay_snapshot = snapshot_of(replay)
      assert replay_snapshot.inputs == before_snapshot.inputs
      assert matrix_input(replay_snapshot).content_hash == cast.matrix.content_hash

      # And the digest is sensitive to exactly that one input: swap the matrix input in
      # the first envelope and its digest moves; sealing it unchanged reproduces it.
      swapped = %{
        before_snapshot
        | inputs:
            Enum.map(before_snapshot.inputs, fn
              %{role: :travel_matrix} = input -> %{input | content_hash: v2.content_hash}
              other -> other
            end)
      }

      assert PlanningSnapshot.seal(before_snapshot).digest == before_snapshot.digest
      refute PlanningSnapshot.seal(swapped).digest == before_snapshot.digest
    end

    test "a plan approved on one matrix is refused as stale once another is published" do
      cast = one_visit_cast()
      {:ok, %{candidates: [candidate]}} = plan_one(cast)
      assert candidate.check_status == :correct

      {:ok, _instance} = MobileVisits.submit_for_approval(candidate)
      tasks = FourEyes.tasks(candidate.id)
      {:ok, _} = FourEyes.sign(tasks["ManagerSignoff"].id, :approved, as(cast.manager))

      publish_matrix!(cast.places, "clinic_van", %{{:clinic, :a} => 25})
      appointments_before = Scheduling.list_appointments!(authorize?: false)

      assert {:error, error} =
               FourEyes.sign(tasks["HeadVetSignoff"].id, :approved, as(cast.head_vet))

      assert Exception.message(error) =~ "a source changed since the snapshot"
      assert Exception.message(error) =~ "travel_matrix:clinic_van"

      refused = Ash.get!(Planning.Candidate, candidate.id, authorize?: false)
      assert {refused.disposition, refused.freshness} == {:rejected, :stale}
      assert Scheduling.list_appointments!(authorize?: false) == appointments_before
      assert Scheduling.get_visit_request!(cast.visit.id).state == :requested
    end

    @tag :solver
    test "solver: the matrix feeds the model, not just the snapshot: another matrix is another drive" do
      cast = one_visit_cast()

      {:ok, %{run: run1, candidates: [v1 | _]}} =
        MobileVisits.plan(day: cast.monday, clinician_id: cast.mobile_vet.id, actor: staff())

      publish_matrix!(cast.places, "clinic_van", %{{:clinic, :a} => 25})

      {:ok, %{run: run2, candidates: [v2 | _]}} =
        MobileVisits.plan(day: cast.monday, clinician_id: cast.mobile_vet.id, actor: staff())

      refute run1.snapshot_digest == run2.snapshot_digest
      first_leg = fn candidate -> hd(decoded(candidate)["legs"])["minutes"] end
      assert {first_leg.(v1), first_leg.(v2)} == {20, 25}
      assert v1.check_status == :correct and v2.check_status == :correct
    end
  end

  defp decoded(candidate), do: Jason.decode!(candidate.assignments)
end
