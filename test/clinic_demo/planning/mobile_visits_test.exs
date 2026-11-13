defmodule ClinicDemo.Planning.MobileVisitsTest do
  @moduledoc """
  The mobile-visits pipeline's honesty: what each axis says when the answer is not a
  plan, what the snapshot reads (the vet's calendar as the roster left it, as of the
  knowledge cutoff), and what applying a plan writes.

  Driven through `AshPlanning.Backend.Fake`; the real-model equivalents are in
  `ClinicDemo.Planning.MobileExitsTest` (`:solver`) plus the two `:solver` cases below.
  """

  use ClinicDemo.DataCase, async: false

  import ClinicDemo.MobileFixtures
  import ClinicDemo.PlanningFixtures, only: [staff: 0, next_monday: 0, team!: 0, type!: 1]

  alias ClinicDemo.BusinessEvents
  alias ClinicDemo.Planning
  alias ClinicDemo.Planning.{FourEyes, MobileVisits, SnapshotBuilder}
  alias ClinicDemo.Scheduling
  alias Ecto.Adapters.SQL

  setup do
    BusinessEvents.install!()
    team = team!()
    places = places!()
    %{team: team, places: places, vet: team.vet, monday: next_monday()}
  end

  defp prepared_problem(run) do
    {:ok, payload} = SnapshotBuilder.problem_payload(run)
    payload["problem"]
  end

  defp unresolved(run), do: Map.new(run.unresolved_inputs, &{&1["id"], &1["reason"]})

  describe "inputs that cannot be planned make the run needs_input, naming them" do
    test "equipment the vet's kit does not carry", c do
      publish_matrix!(c.places)
      type = mobile_type!("Farm vaccination", ["vaccine_cooler"])
      visit = request_visit!(c.monday, {10, 0}, {12, 0}, c.places.a, type: type)

      {:ok, %{run: run, candidates: []}} = plan_fake(c.monday, c.vet, staff(), %{})

      assert run.preparation_status == :needs_input
      assert run.solve_status == nil
      assert run.snapshot_digest
      assert unresolved(run) == %{"visit_request:#{visit.id}" => "equipment_not_carried"}

      # A kit with the cooler plans.
      equipped = mobile_vet!("Dr. Kit Kent", ["vaccine_cooler"])
      starts = %{visit.id => {10, 0}}
      {:ok, %{run: ok_run}} = plan_fake(c.monday, equipped, staff(), starts)
      assert ok_run.preparation_status == :prepared
    end

    test "a visit type that cannot be done away from the clinic", c do
      publish_matrix!(c.places)
      visit = request_visit!(c.monday, {10, 0}, {12, 0}, c.places.a, type: type!("Dental clean"))

      {:ok, %{run: run}} = plan_fake(c.monday, c.vet, staff(), %{})

      assert run.preparation_status == :needs_input
      assert unresolved(run) == %{"visit_request:#{visit.id}" => "type_not_mobile_capable"}
    end

    test "a pair the matrix does not hold is named, never read as zero", c do
      publish_matrix!(c.places, "clinic_van", %{{:a, :b} => :missing})
      request_visit!(c.monday, {10, 0}, {12, 0}, c.places.a)
      request_visit!(c.monday, {10, 0}, {14, 0}, c.places.b)

      {:ok, %{run: run, candidates: []}} = plan_fake(c.monday, c.vet, staff(), %{})

      assert run.preparation_status == :needs_input

      assert unresolved(run) == %{
               "travel_pair:#{c.places.a.id}:#{c.places.b.id}" => "travel_pair_missing",
               "travel_pair:#{c.places.b.id}:#{c.places.a.id}" => "travel_pair_missing"
             }
    end

    test "no published matrix at all", c do
      request_visit!(c.monday, {10, 0}, {12, 0}, c.places.a)

      {:ok, %{run: run}} = plan_fake(c.monday, c.vet, staff(), %{})

      assert run.preparation_status == :needs_input
      assert unresolved(run) == %{"travel_matrix:clinic_van" => "no_published_matrix"}
    end

    test "a matrix row edited behind the resource's back is refused by its hash", c do
      matrix = publish_matrix!(c.places)
      request_visit!(c.monday, {10, 0}, {12, 0}, c.places.a)

      SQL.query!(
        ClinicDemo.Repo,
        "UPDATE scheduling_travel_matrices SET provider = 'tampered' WHERE id = $1",
        [Ecto.UUID.dump!(matrix.id)]
      )

      {:ok, %{run: run}} = plan_fake(c.monday, c.vet, staff(), %{})
      assert run.preparation_status == :needs_input
      assert unresolved(run) == %{"travel_matrix:clinic_van" => "matrix_hash_mismatch"}
    end

    test "pinned work that overlaps other pinned work", c do
      publish_matrix!(c.places)
      first = in_clinic!(c.monday, {10, 0}, c.vet)
      second = in_clinic!(c.monday, {10, 15}, c.vet)
      request_visit!(c.monday, {13, 0}, {15, 0}, c.places.a)

      {:ok, %{run: run}} = plan_fake(c.monday, c.vet, staff(), %{})

      assert run.preparation_status == :needs_input
      assert unresolved(run) == %{"appointment:#{second.id}" => "commitment_overlap"}
      refute Map.has_key?(unresolved(run), "appointment:#{first.id}")
    end

    test "a booked visit whose appointment has since been cancelled", c do
      publish_matrix!(c.places)
      visit = request_visit!(c.monday, {10, 0}, {12, 0}, c.places.a)

      {:ok, %{candidates: [candidate]}} =
        plan_fake(c.monday, c.vet, staff(), %{visit.id => {10, 0}})

      {:ok, _} = approve_and_apply(candidate, c.team)

      appointment = hd(mobile_appointments())
      Scheduling.cancel_appointment!(appointment, "cancelled at the front desk", actor: staff())

      {:ok, %{run: run}} = plan_fake(c.monday, c.vet, staff(), %{})
      assert run.preparation_status == :needs_input

      assert unresolved(run) == %{
               "visit_request:#{visit.id}" => "linked_appointment_not_scheduled"
             }
    end
  end

  describe "a plan that cannot start" do
    test "a clinician who is not a veterinarian", c do
      {:ok, %{run: run}} = plan_fake(c.monday, c.team.tech, staff(), %{})
      assert run.preparation_status == :preparation_failed
      assert run.stats["reason"] == "clinician_unavailable"
      assert run.stats["day"] == Date.to_iso8601(c.monday)
    end

    test "no clinic to start the day from", c do
      Scheduling.retire_service_location!(c.places.clinic, actor: staff())
      {:ok, %{run: run}} = plan_fake(c.monday, c.vet, staff(), %{})
      assert run.preparation_status == :preparation_failed
      assert run.stats["reason"] == "no_clinic_location"
    end
  end

  describe "the vet's calendar is the same one the roster composes" do
    setup c do
      publish_matrix!(c.places)
      %{visit: request_visit!(c.monday, {8, 0}, {17, 0}, c.places.a)}
    end

    test "an applied shift is the working window", c do
      place_shift!(c.vet, c.monday, {9, 0}, {12, 0})

      {:ok, %{run: run}} = plan_fake(c.monday, c.vet, staff(), %{c.visit.id => {9, 30}})
      problem = prepared_problem(run)

      assert problem["work_from"] == "#{c.monday}T09:00:00Z"
      assert problem["work_to"] == "#{c.monday}T12:00:00Z"
    end

    test "without a shift: 08:00 to 18:00, widened to hold pinned work", c do
      in_clinic!(c.monday, {7, 30}, c.vet)

      {:ok, %{run: run}} = plan_fake(c.monday, c.vet, staff(), %{c.visit.id => {9, 0}})
      problem = prepared_problem(run)

      assert problem["work_from"] == "#{c.monday}T07:30:00Z"
      assert problem["work_to"] == "#{c.monday}T18:00:00Z"
    end

    test "the attendee is the applied assignment, not the booked clinician", c do
      booked_for_vet = in_clinic!(c.monday, {10, 0}, c.vet)
      booked_for_head = in_clinic!(c.monday, {13, 0}, c.team.head_vet)

      # The roster moved the vet's appointment to the head vet and the head vet's to the vet.
      assign!(booked_for_vet, c.team.head_vet)
      assign!(booked_for_head, c.vet)

      {:ok, %{run: run}} = plan_fake(c.monday, c.vet, staff(), %{c.visit.id => {9, 0}})
      problem = prepared_problem(run)

      assert Enum.map(problem["commitments"], & &1["id"]) == [booked_for_head.id]
    end

    test "telehealth blocks the vet's time without a place; unlinked mobile work is pinned at its place",
         c do
      telehealth = book!(c, {11, 0}, c.vet, location_mode: :telehealth)

      on_the_road =
        book!(c, {14, 0}, c.vet, location_mode: :mobile, service_location_id: c.places.b.id)

      {:ok, %{run: run}} = plan_fake(c.monday, c.vet, staff(), %{c.visit.id => {9, 0}})
      problem = prepared_problem(run)

      assert [%{"id" => id, "kind" => "telehealth"}] = problem["blocked"]
      assert id == telehealth.id

      assert [%{"id" => commitment_id, "location_id" => location}] = problem["commitments"]
      assert commitment_id == on_the_road.id
      assert location == c.places.b.id
    end

    test "removed availability is read as of the cutoff", c do
      cutoff = DateTime.utc_now()
      Process.sleep(20)

      Scheduling.declare_availability!(
        %{
          clinician_id: c.vet.id,
          starts_at: DateTime.new!(c.monday, ~T[12:00:00], "Etc/UTC"),
          ends_at: DateTime.new!(c.monday, ~T[13:00:00], "Etc/UTC"),
          available: false,
          reason: "leave"
        },
        actor: staff()
      )

      starts = %{c.visit.id => {9, 0}}
      {:ok, %{run: seen}} = plan_fake(c.monday, c.vet, staff(), starts, cutoff: cutoff)
      {:ok, %{run: knows}} = plan_fake(c.monday, c.vet, staff(), starts)

      assert prepared_problem(seen)["blocked"] == []
      assert [%{"kind" => "unavailable"}] = prepared_problem(knows)["blocked"]
      assert seen.stats["inputs"] + 1 == knows.stats["inputs"]
    end

    test "a cancellation after the cutoff is not seen", c do
      cutoff = DateTime.utc_now()
      Process.sleep(20)
      Scheduling.cancel_visit_request!(c.visit.id, "owner called it off", actor: staff())

      {:ok, %{run: seen}} =
        plan_fake(c.monday, c.vet, staff(), %{c.visit.id => {9, 0}}, cutoff: cutoff)

      {:ok, %{run: after_cut}} = plan_fake(c.monday, c.vet, staff(), %{})

      assert seen.stats["visits"] == 1
      assert after_cut.stats["visits"] == 0
    end
  end

  describe "applying a plan" do
    setup c do
      publish_matrix!(c.places)
      %{visit: request_visit!(c.monday, {8, 0}, {14, 0}, c.places.b, minutes: 30)}
    end

    test "books a mobile appointment for the booked time (not the access buffer) and schedules the request",
         c do
      {:ok, %{candidates: [candidate]}} =
        plan_fake(c.monday, c.vet, staff(), %{c.visit.id => {10, 0}})

      assert candidate.check_status == :correct
      assert candidate.unresolved_obligations == []
      assert mobile_appointments() == []

      {:ok, applied} = approve_and_apply(candidate, c.team)
      assert applied.disposition == :applied

      assert [appointment] = mobile_appointments()
      assert appointment.location_mode == :mobile
      assert appointment.service_location_id == c.places.b.id
      assert appointment.clinician_id == c.vet.id
      assert appointment.patient_id == c.visit.patient_id
      assert appointment.scheduled_at == DateTime.new!(c.monday, ~T[10:00:00], "Etc/UTC")
      # Farm B's gate adds five planned minutes; the booking is the thirty requested.
      assert appointment.duration_minutes == 30

      request = Scheduling.get_visit_request!(c.visit.id)
      assert request.state == :scheduled
      assert request.appointment_id == appointment.id
    end

    test "a replan that has to move a booked visit reschedules its appointment, not books another",
         c do
      {:ok, %{candidates: [first]}} =
        plan_fake(c.monday, c.vet, staff(), %{c.visit.id => {10, 0}})

      {:ok, _} = approve_and_apply(first, c.team)
      [booked] = mobile_appointments()

      # A new in-clinic booking lands on the visit's slot: pinned work does not move.
      in_clinic!(c.monday, {10, 0}, c.vet)

      {:ok, %{candidates: [second]}} =
        plan_fake(c.monday, c.vet, staff(), %{c.visit.id => {11, 15}})

      assert second.check_status == :correct
      plan = Jason.decode!(second.assignments)
      assert {plan["moved_visits"], plan["preserved_visits"]} == {1, 0}

      {:ok, applied} = approve_and_apply(second, c.team)

      assert Map.take(applied.__metadata__[:planning_apply], [
               :booked_visits,
               :moved_visits,
               :preserved_visits
             ]) == %{booked_visits: 0, moved_visits: 1, preserved_visits: 0}

      assert [moved] = mobile_appointments()
      assert moved.id == booked.id
      assert moved.scheduled_at == DateTime.new!(c.monday, ~T[11:15:00], "Etc/UTC")
    end

    test "a newer plan for the same day and vet supersedes the undecided one; another vet's is untouched",
         c do
      other = mobile_vet!("Dr. Other Oak")
      starts = %{c.visit.id => {10, 0}}

      {:ok, %{candidates: [first]}} = plan_fake(c.monday, c.vet, staff(), starts)
      {:ok, %{candidates: [for_other]}} = plan_fake(c.monday, other, staff(), starts)
      {:ok, %{candidates: [second]}} = plan_fake(c.monday, c.vet, staff(), starts)

      disposition = fn candidate ->
        Ash.get!(Planning.Candidate, candidate.id, authorize?: false).disposition
      end

      assert disposition.(first) == :superseded
      assert disposition.(for_other) == :proposed
      assert disposition.(second) == :proposed
    end

    test "a rejection books nothing and leaves the request open", c do
      {:ok, %{candidates: [candidate]}} =
        plan_fake(c.monday, c.vet, staff(), %{c.visit.id => {10, 0}})

      {:ok, _} = MobileVisits.submit_for_approval(candidate)
      tasks = FourEyes.tasks(candidate.id)

      assert {:ok, rejected} =
               FourEyes.sign(tasks["ManagerSignoff"].id, :rejected, %{id: c.team.manager.id})

      assert rejected.disposition == :rejected
      assert mobile_appointments() == []
      assert Scheduling.get_visit_request!(c.visit.id).state == :requested
    end

    test "an unapproved candidate cannot be applied, and nobody can schedule a request around the plan",
         c do
      {:ok, %{candidates: [candidate]}} =
        plan_fake(c.monday, c.vet, staff(), %{c.visit.id => {10, 0}})

      assert {:error, _} = Planning.apply_candidate(candidate, %{}, actor: %{id: c.vet.id})
      assert mobile_appointments() == []

      assert {:error, %Ash.Error.Forbidden{}} =
               Scheduling.schedule_visit_request(c.visit.id, Ecto.UUID.generate(),
                 actor: %{id: c.team.manager.id}
               )
    end

    test "a booking that lands on the vet's calendar after the plan was made makes it stale", c do
      {:ok, %{candidates: [candidate]}} =
        plan_fake(c.monday, c.vet, staff(), %{c.visit.id => {10, 0}})

      {:ok, _} = MobileVisits.submit_for_approval(candidate)
      tasks = FourEyes.tasks(candidate.id)
      {:ok, _} = FourEyes.sign(tasks["ManagerSignoff"].id, :approved, %{id: c.team.manager.id})

      in_clinic!(c.monday, {10, 0}, c.vet)

      assert {:error, error} =
               FourEyes.sign(tasks["HeadVetSignoff"].id, :approved, %{id: c.team.head_vet.id})

      assert Exception.message(error) =~ "a source changed since the snapshot"
      assert mobile_appointments() == []
      assert Scheduling.get_visit_request!(c.visit.id).state == :requested
    end
  end

  describe "the real model (:solver)" do
    @describetag :solver

    test "a pair that cannot be driven is refused, never zero-cost", c do
      # Farms A and C: nothing but each other and the clinic, and the clinic is only the
      # start and end of the day. Any route visits one then the other.
      request_visit!(c.monday, {9, 0}, {16, 0}, c.places.a)
      request_visit!(c.monday, {9, 0}, {16, 0}, c.places.c)

      publish_matrix!(c.places, "clinic_van", %{{:a, :c} => :unreachable})

      {:ok, %{run: run, candidates: []}} =
        MobileVisits.plan(day: c.monday, clinician_id: c.vet.id, actor: staff())

      assert {run.solve_status, run.complete?} == {:infeasible, true}

      # The very same requests are fine when the pair can be driven (35 minutes).
      publish_matrix!(c.places)

      {:ok, %{run: run2, candidates: [candidate | _]}} =
        MobileVisits.plan(day: c.monday, clinician_id: c.vet.id, actor: staff())

      assert run2.solve_status == :optimal
      assert candidate.check_status == :correct

      legs = Jason.decode!(candidate.assignments)["legs"]
      between = Enum.find(legs, &(&1["from"] =~ "visit_request" and &1["to"] =~ "visit_request"))
      assert between["minutes"] == 35
    end

    test "the solver orders visits to cut driving, plans the gate buffer and keeps service and drive out of blocked time",
         c do
      publish_matrix!(c.places)
      a = request_visit!(c.monday, {12, 0}, {17, 0}, c.places.a)
      b = request_visit!(c.monday, {12, 0}, {17, 0}, c.places.b)
      cc = request_visit!(c.monday, {12, 0}, {17, 0}, c.places.c)

      lunch_from = DateTime.new!(c.monday, ~T[12:00:00], "Etc/UTC")
      lunch_to = DateTime.new!(c.monday, ~T[13:00:00], "Etc/UTC")

      Scheduling.declare_availability!(
        %{
          clinician_id: c.vet.id,
          starts_at: lunch_from,
          ends_at: lunch_to,
          available: false,
          reason: "lunch"
        },
        actor: staff()
      )

      {:ok, %{run: run, candidates: [candidate | _]}} =
        MobileVisits.plan(day: c.monday, clinician_id: c.vet.id, actor: staff())

      assert run.solve_status == :optimal
      assert candidate.check_status == :correct

      plan = Jason.decode!(candidate.assignments)
      order = Enum.map(plan["stops"], & &1["visit_request_id"])

      # Of the six orders the shortest drive is 100 minutes: A, C, B or its reverse.
      assert order in [[a.id, cc.id, b.id], [b.id, cc.id, a.id]]
      assert plan["legs"] |> Enum.map(& &1["minutes"]) |> Enum.sum() == 100

      # Farm B's gate is planned time: 30 booked + 5 buffer.
      b_stop = Enum.find(plan["stops"], &(&1["visit_request_id"] == b.id))
      assert {b_stop["booked_minutes"], b_stop["service_minutes"]} == {30, 35}

      # Nothing is planned across lunch: not the service, not the drive.
      intervals =
        Enum.map(plan["stops"], &{&1["starts_at"], &1["ends_at"]}) ++
          Enum.map(plan["legs"], &{&1["departs_at"], &1["arrives_at"]})

      for {from, to} <- intervals do
        {:ok, from, _} = DateTime.from_iso8601(from)
        {:ok, to, _} = DateTime.from_iso8601(to)

        refute DateTime.compare(from, lunch_to) == :lt and DateTime.compare(lunch_from, to) == :lt
      end
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp mobile_appointments do
    Scheduling.list_appointments!(authorize?: false)
    |> Enum.filter(&(&1.location_mode == :mobile and &1.status == :scheduled))
  end

  # Two different approvers, each as themselves; the second signature applies.
  defp approve_and_apply(candidate, team) do
    {:ok, _instance} = MobileVisits.submit_for_approval(candidate)
    tasks = FourEyes.tasks(candidate.id)

    {:ok, _} = FourEyes.sign(tasks["ManagerSignoff"].id, :approved, %{id: team.manager.id})
    FourEyes.sign(tasks["HeadVetSignoff"].id, :approved, %{id: team.head_vet.id})
  end

  # An appointment with a patient, on `c.monday`, in any location mode.
  defp book!(c, {hour, minute}, clinician, extra) do
    patient =
      Scheduling.register_patient!(
        %{
          name: "Patient #{System.unique_integer([:positive])}",
          species: :cat,
          owner_email: "owner-#{System.unique_integer([:positive])}@example.com"
        },
        actor: staff()
      )

    Scheduling.book_appointment!(
      Map.merge(
        %{
          patient_id: patient.id,
          clinician_id: clinician.id,
          scheduled_at: DateTime.new!(c.monday, Time.new!(hour, minute, 0), "Etc/UTC"),
          duration_minutes: 30,
          reason: "Synthetic checkup"
        },
        Map.new(extra)
      ),
      actor: staff()
    )
  end

  # Rows the weekly roster would have written by applying a candidate; the tests write
  # them directly (policy bypassed) because the roster is not what is under test.
  defp place_shift!(clinician, monday, {from_h, from_m}, {to_h, to_m}) do
    Ash.create!(
      ClinicDemo.Scheduling.Shift,
      %{
        role: :veterinarian,
        starts_at: DateTime.new!(monday, Time.new!(from_h, from_m, 0), "Etc/UTC"),
        ends_at: DateTime.new!(monday, Time.new!(to_h, to_m, 0), "Etc/UTC"),
        candidate_id: Ecto.UUID.generate(),
        clinician_id: clinician.id
      },
      action: :place,
      authorize?: false
    )
  end

  defp assign!(appointment, clinician) do
    Ash.create!(
      ClinicDemo.Scheduling.Assignment,
      %{
        appointment_id: appointment.id,
        role: clinician.role,
        candidate_id: Ecto.UUID.generate(),
        clinician_id: clinician.id
      },
      action: :place,
      authorize?: false
    )
  end
end
