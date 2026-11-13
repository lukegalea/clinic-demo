defmodule ClinicDemo.Planning.FourEyesTest do
  @moduledoc """
  Who may approve and apply a roster candidate, and what refuses a stale one.

  The authority claims, each tested from the outside (as a person, or as machinery,
  calling the action):

    * nobody but the clinic manager AND the head vet, two different clinicians, can
      approve or apply a candidate: not staff, not the planner, not one approver
      alone, not a person holding both leadership positions signing both tasks;
    * `Shift` and `Assignment` cannot be created, edited or deleted by a person
      directly, nor by passing the apply context by hand;
    * a rejection by either approver rejects the candidate and withdraws the other
      task, so no orphan task is left on a worklist;
    * any drift in what the plan read refuses the apply, rolls back every write and
      leaves the candidate `:rejected` and `:stale`: a rescheduled appointment, a
      cancelled one, a revised availability, a shift applied by another candidate;
    * applying starts the visit process only for an appointment that has none.
  """

  use ClinicDemo.DataCase, async: false

  import ClinicDemo.PlanningFixtures

  require Ash.Query

  alias Ash.Error.Forbidden
  alias ClinicDemo.Planning
  alias ClinicDemo.Planning.Checks.AppliedByCandidate
  alias ClinicDemo.Planning.{FourEyes, Machinery, WeeklyRoster}
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Visits.{HumanTask, Instance, TaskDesk}

  defp setup_week do
    team = team!()
    monday = next_monday()
    type = type!("Wellness exam")
    a1 = book!(monday, 1, {10, 0}, team.vet, type: type)
    a2 = book!(monday, 1, {11, 0}, team.vet, type: type)

    script = fn _payload ->
      {[{team.vet.id, 1, "early"}], [{a1.id, team.vet.id}, {a2.id, team.vet.id}]}
    end

    {:ok, %{candidates: [candidate]}} = plan_fake(monday, staff(), script)
    {:ok, _instance} = WeeklyRoster.submit_for_approval(candidate)

    %{
      team: team,
      monday: monday,
      a1: a1,
      a2: a2,
      candidate: candidate,
      script: script,
      tasks: FourEyes.tasks(candidate.id)
    }
  end

  defp as(clinician), do: %{id: clinician.id}

  describe "the approval process" do
    test "starts a manager task and a head vet task, each for its own position only" do
      w = setup_week()

      assert Map.keys(w.tasks) |> Enum.sort() == ["HeadVetSignoff", "ManagerSignoff"]
      assert Enum.all?(Map.values(w.tasks), &(&1.status == :open))

      candidates = fn task ->
        ClinicDemo.Visits.TaskCandidate
        |> Ash.Query.filter(task_id == ^task.id)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.principal_id)
      end

      assert candidates.(w.tasks["ManagerSignoff"]) == [w.team.manager.id]
      assert candidates.(w.tasks["HeadVetSignoff"]) == [w.team.head_vet.id]
    end

    test "only the position a task is for may sign it" do
      w = setup_week()

      for outsider <- [w.team.tech, w.team.vet, w.team.head_vet] do
        assert {:error, %Forbidden{}} =
                 FourEyes.sign(w.tasks["ManagerSignoff"].id, :approved, as(outsider))
      end

      assert {:error, %Forbidden{}} =
               FourEyes.sign(w.tasks["HeadVetSignoff"].id, :approved, as(w.team.manager))

      assert Ash.get!(Planning.Candidate, w.candidate.id, authorize?: false).disposition ==
               :proposed
    end

    test "one clinician cannot satisfy both sign-offs, even if they are a candidate for both" do
      w = setup_week()

      # The roster resolves one position per clinician, so make the head vet a candidate
      # for the manager's task as well, the way a misconfigured roster could.
      Ash.Seed.seed!(ClinicDemo.Visits.TaskCandidate, %{
        task_id: w.tasks["ManagerSignoff"].id,
        principal_type: :user,
        principal_id: w.team.head_vet.id
      })

      {:ok, _} = FourEyes.sign(w.tasks["HeadVetSignoff"].id, :approved, as(w.team.head_vet))

      # They already signed one task: they may not sign the other, though they may take it.
      assert {:error, %Forbidden{}} =
               FourEyes.sign(w.tasks["ManagerSignoff"].id, :approved, as(w.team.head_vet))

      assert FourEyes.signers(w.candidate.id) == :incomplete

      assert Ash.get!(Planning.Candidate, w.candidate.id, authorize?: false).disposition ==
               :proposed
    end

    test "a rejection by either approver rejects the candidate and the engine cancels the other task" do
      w = setup_week()

      assert {:ok, rejected} =
               FourEyes.sign(w.tasks["HeadVetSignoff"].id, :rejected, as(w.team.head_vet))

      assert rejected.disposition == :rejected

      tasks = FourEyes.tasks(w.candidate.id)
      assert tasks["HeadVetSignoff"].outcome == "rejected"
      # Engine-native withdraw: the process is cancelled, so the sibling task
      # is cancelled by the engine (not completed-withdrawn by the planner).
      assert tasks["ManagerSignoff"].status == :cancelled
      assert tasks["ManagerSignoff"].outcome == nil

      # The engine cancelled the process: exactly one instance, status
      # :cancelled, and no open or claimed sign-off work left behind.
      instance_ids = tasks |> Map.values() |> Enum.map(& &1.instance_id) |> Enum.uniq()
      assert length(instance_ids) == 1

      require Ash.Query

      refute Enum.any?(
               ClinicDemo.Visits.HumanTask
               |> Ash.Query.filter(
                 instance_id == ^hd(instance_ids) and status in [:open, :claimed]
               )
               |> Ash.read!(authorize?: false)
             )

      assert %{status: :cancelled} =
               Ash.get!(ClinicDemo.Visits.Instance, hd(instance_ids), authorize?: false)

      assert Scheduling.list_shifts!(authorize?: false) == []
    end

    test "a decided candidate takes no further signatures" do
      w = setup_week()
      {:ok, _} = FourEyes.sign(w.tasks["HeadVetSignoff"].id, :rejected, as(w.team.head_vet))

      assert {:error, %Forbidden{}} =
               FourEyes.sign(w.tasks["ManagerSignoff"].id, :approved, as(w.team.manager))
    end
  end

  describe "authority" do
    test "staff, the planner and a lone approver cannot approve or apply" do
      w = setup_week()

      for actor <- [staff(), Machinery.actor(), as(w.team.manager), as(w.team.head_vet), nil] do
        assert {:error, %Forbidden{}} = Planning.approve_candidate(w.candidate, %{}, actor: actor)

        # `apply` of a candidate that is not approved is refused by its own guard before
        # authorization is asked; either way nothing is applied.
        assert {:error, %{class: class}} =
                 Planning.apply_candidate(w.candidate, %{}, actor: actor)

        assert class in [:forbidden, :invalid]
      end

      assert Ash.get!(Planning.Candidate, w.candidate.id, authorize?: false).disposition ==
               :proposed

      {:ok, _} = FourEyes.sign(w.tasks["ManagerSignoff"].id, :approved, as(w.team.manager))

      # Half the sign-offs is still not the sign-off.
      assert {:error, %Forbidden{}} =
               Planning.approve_candidate(w.candidate, %{}, actor: as(w.team.manager))
    end

    test "only leadership may reject; the planner and staff may not" do
      w = setup_week()

      for actor <- [staff(), Machinery.actor(), as(w.team.tech), as(w.team.vet)] do
        assert {:error, %Forbidden{}} = Planning.reject_candidate(w.candidate, %{}, actor: actor)
      end

      assert {:ok, %{disposition: :rejected}} =
               Planning.reject_candidate(w.candidate, %{}, actor: as(w.team.manager))
    end

    test "a person cannot write a run's axes or a candidate's plan, check or freshness" do
      w = setup_week()
      run = Ash.get!(Planning.Run, w.candidate.run_id, authorize?: false)

      assert {:error, %Forbidden{}} =
               Planning.record_run_result(
                 run,
                 %{solve_status: :optimal, complete?: true, optimality: :optimal, epoch: 1},
                 actor: staff()
               )

      assert {:error, %Forbidden{}} =
               Planning.mark_candidate_stale(w.candidate, %{}, actor: as(w.team.manager))

      assert {:error, %Forbidden{}} =
               Planning.record_candidate_check(w.candidate, %{check_status: :correct},
                 actor: staff()
               )

      assert {:error, %Forbidden{}} =
               Planning.propose_candidate(%{run_id: run.id, index: 9, assignments: "{}"},
                 actor: staff()
               )
    end

    test "no person creates, edits or deletes a shift or an assignment directly" do
      w = setup_week()

      shift_params = %{
        role: :veterinarian,
        starts_at: DateTime.new!(w.monday, ~T[08:00:00], "Etc/UTC"),
        ends_at: DateTime.new!(w.monday, ~T[16:00:00], "Etc/UTC"),
        candidate_id: w.candidate.id,
        clinician_id: w.team.vet.id
      }

      for actor <- [staff(), Machinery.actor(), as(w.team.manager), as(w.team.head_vet)] do
        assert {:error, %Forbidden{}} = Scheduling.place_shift(shift_params, actor: actor)

        assert {:error, %Forbidden{}} =
                 Scheduling.place_assignment(
                   %{
                     appointment_id: w.a1.id,
                     role: :veterinarian,
                     candidate_id: w.candidate.id,
                     clinician_id: w.team.vet.id
                   },
                   actor: actor
                 )
      end
    end

    # Both tasks signed by the two approvers, candidate approved, NOT yet applied.
    defp approved_unapplied(w, candidate) do
      tasks = FourEyes.tasks(candidate.id)

      {:ok, _} =
        TaskDesk.complete(
          tasks["ManagerSignoff"].id,
          :approved,
          nil,
          as(w.team.manager)
        )

      {:ok, _} =
        TaskDesk.complete(
          tasks["HeadVetSignoff"].id,
          :approved,
          nil,
          as(w.team.head_vet)
        )

      {:ok, approved} = Planning.approve_candidate(candidate, %{}, actor: as(w.team.head_vet))
      assert approved.disposition == :approved
      approved
    end

    test "a signer cannot forge placements in the approved-but-unapplied window" do
      w = setup_week()
      approved = approved_unapplied(w, w.candidate)

      shift_params = %{
        role: :veterinarian,
        starts_at: DateTime.new!(w.monday, ~T[08:00:00], "Etc/UTC"),
        ends_at: DateTime.new!(w.monday, ~T[16:00:00], "Etc/UTC"),
        candidate_id: approved.id,
        clinician_id: w.team.vet.id
      }

      forged = %{planning_apply: %{candidate_id: approved.id}}

      for opts <- [[actor: as(w.team.head_vet), context: forged], [actor: as(w.team.manager)]] do
        assert {:error, %Forbidden{}} = Scheduling.place_shift(shift_params, opts)

        assert {:error, %Forbidden{}} =
                 Scheduling.place_assignment(
                   %{
                     appointment_id: w.a1.id,
                     role: :veterinarian,
                     candidate_id: approved.id,
                     clinician_id: w.team.vet.id
                   },
                   opts
                 )
      end

      assert Scheduling.list_shifts!(authorize?: false) == []
      assert Scheduling.list_assignments!(authorize?: false) == []

      # The legitimate path still writes.
      {:ok, applied} = Planning.apply_candidate(approved, %{}, actor: as(w.team.head_vet))
      assert applied.disposition == :applied
      assert length(Scheduling.list_shifts!(authorize?: false)) == 1
    end

    test "a signer of one candidate cannot cancel another candidate's rows" do
      w = setup_week()
      {:ok, _} = FourEyes.sign(w.tasks["ManagerSignoff"].id, :approved, as(w.team.manager))
      {:ok, applied} = FourEyes.sign(w.tasks["HeadVetSignoff"].id, :approved, as(w.team.head_vet))
      assert applied.disposition == :applied

      [shift] = Scheduling.list_shifts!(authorize?: false)
      [assignment | _] = Scheduling.list_assignments!(authorize?: false)

      {:ok, %{candidates: [other]}} = plan_fake(w.monday, staff(), w.script)
      {:ok, _instance} = WeeklyRoster.submit_for_approval(other)
      approved = approved_unapplied(w, other)

      # Even with the apply marker genuinely set for the other candidate, rows its
      # diff did not select (here none) are not its to cancel.
      AppliedByCandidate.with_marker(approved.id, MapSet.new(), fn ->
        assert {:error, %Forbidden{}} =
                 Scheduling.cancel_shift(shift, %{}, actor: as(w.team.head_vet))

        assert {:error, %Forbidden{}} =
                 Scheduling.cancel_assignment(assignment, %{}, actor: as(w.team.head_vet))
      end)

      assert Ash.get!(ClinicDemo.Scheduling.Shift, shift.id, authorize?: false).state ==
               :scheduled
    end

    test "forging the apply context is not enough: the candidate must be approved, signed and current" do
      w = setup_week()
      forged = %{planning_apply: %{candidate_id: w.candidate.id}}

      shift_params = %{
        role: :veterinarian,
        starts_at: DateTime.new!(w.monday, ~T[08:00:00], "Etc/UTC"),
        ends_at: DateTime.new!(w.monday, ~T[16:00:00], "Etc/UTC"),
        candidate_id: w.candidate.id,
        clinician_id: w.team.vet.id
      }

      # Unsigned.
      assert {:error, %Forbidden{}} =
               Scheduling.place_shift(shift_params, actor: as(w.team.head_vet), context: forged)

      # Even after both sign (the candidate is applied by that signature, so a second
      # hand-made write finds it no longer :approved).
      {:ok, _} = FourEyes.sign(w.tasks["ManagerSignoff"].id, :approved, as(w.team.manager))
      {:ok, applied} = FourEyes.sign(w.tasks["HeadVetSignoff"].id, :approved, as(w.team.head_vet))
      assert applied.disposition == :applied

      assert {:error, %Forbidden{}} =
               Scheduling.place_shift(shift_params, actor: as(w.team.head_vet), context: forged)

      # And a row attributed to another candidate than the context names is refused.
      assert {:error, %Forbidden{}} =
               Scheduling.place_shift(%{shift_params | candidate_id: Ash.UUID.generate()},
                 actor: as(w.team.head_vet),
                 context: forged
               )
    end
  end

  describe "drift refuses the apply" do
    defp assert_refused(w, result) do
      assert {:error, error} = result
      assert Exception.message(error) =~ "a source changed since the snapshot"

      candidate = Ash.get!(Planning.Candidate, w.candidate.id, authorize?: false)
      assert candidate.disposition == :rejected
      assert candidate.freshness == :stale

      # Nothing was written, not even the writes that would have come first.
      assert Scheduling.list_shifts!(authorize?: false) == []
      assert Scheduling.list_assignments!(authorize?: false) == []
    end

    test "a concurrent booking" do
      w = setup_week()
      {:ok, _} = FourEyes.sign(w.tasks["ManagerSignoff"].id, :approved, as(w.team.manager))
      book!(w.monday, 1, {14, 0}, w.team.vet, type: type!("Wellness exam"))

      assert_refused(
        w,
        FourEyes.sign(w.tasks["HeadVetSignoff"].id, :approved, as(w.team.head_vet))
      )
    end

    test "an appointment rescheduled after the snapshot" do
      w = setup_week()
      {:ok, _} = FourEyes.sign(w.tasks["ManagerSignoff"].id, :approved, as(w.team.manager))

      w.a1
      |> Ash.Changeset.for_update(
        :reschedule,
        %{scheduled_at: DateTime.new!(w.monday, ~T[13:00:00], "Etc/UTC")},
        actor: staff()
      )
      |> Ash.update!()

      assert_refused(
        w,
        FourEyes.sign(w.tasks["HeadVetSignoff"].id, :approved, as(w.team.head_vet))
      )
    end

    test "an appointment cancelled after the snapshot" do
      w = setup_week()
      {:ok, _} = FourEyes.sign(w.tasks["ManagerSignoff"].id, :approved, as(w.team.manager))

      Scheduling.cancel_appointment!(w.a2, "synthetic cancellation", actor: staff())

      assert_refused(
        w,
        FourEyes.sign(w.tasks["HeadVetSignoff"].id, :approved, as(w.team.head_vet))
      )
    end

    test "availability removed after the snapshot" do
      w = setup_week()
      {:ok, _} = FourEyes.sign(w.tasks["ManagerSignoff"].id, :approved, as(w.team.manager))

      remove_availability!(w.monday, 1, w.team.vet, {12, 0}, {13, 0})

      assert_refused(
        w,
        FourEyes.sign(w.tasks["HeadVetSignoff"].id, :approved, as(w.team.head_vet))
      )
    end

    test "a shift pattern retired after the snapshot" do
      w = setup_week()
      {:ok, _} = FourEyes.sign(w.tasks["ManagerSignoff"].id, :approved, as(w.team.manager))

      Scheduling.retire_shift_template!(w.team.templates[{"early", :veterinarian}],
        actor: staff()
      )

      assert_refused(
        w,
        FourEyes.sign(w.tasks["HeadVetSignoff"].id, :approved, as(w.team.head_vet))
      )
    end

    test "another candidate applied first: the second candidate of the week is stale" do
      w = setup_week()
      {:ok, %{candidates: [other]}} = plan_fake(w.monday, staff(), w.script)

      # Planning again superseded the first candidate; apply the new one, then try the
      # superseded one's sign-off: it is decided, so its tasks are closed.
      {:ok, _instance} = WeeklyRoster.submit_for_approval(other)
      tasks = FourEyes.tasks(other.id)
      {:ok, _} = FourEyes.sign(tasks["ManagerSignoff"].id, :approved, as(w.team.manager))
      {:ok, applied} = FourEyes.sign(tasks["HeadVetSignoff"].id, :approved, as(w.team.head_vet))
      assert applied.disposition == :applied

      assert Ash.get!(Planning.Candidate, w.candidate.id, authorize?: false).disposition ==
               :superseded

      assert {:error, %Forbidden{}} =
               FourEyes.sign(w.tasks["ManagerSignoff"].id, :approved, as(w.team.manager))
    end

    test "a refused apply is atomic: a write that fails half-way rolls every earlier write back" do
      w = setup_week()
      {:ok, _} = FourEyes.sign(w.tasks["ManagerSignoff"].id, :approved, as(w.team.manager))

      # A candidate for a clinician who has since left the roster: the shift placement
      # would be the first write that succeeds, the assignment the one that fails.
      # (Retiring the clinician changes the snapshot's clinician input, so it is drift
      # too; the point asserted is the same: nothing is left behind.)
      Scheduling.retire_clinician!(w.team.vet, actor: staff())

      assert_refused(
        w,
        FourEyes.sign(w.tasks["HeadVetSignoff"].id, :approved, as(w.team.head_vet))
      )
    end
  end

  describe "starting the operating process" do
    test "an applied assignment starts the visit process only for an appointment that has none" do
      w = setup_week()

      with_instance =
        Instance |> Ash.Query.filter(subject_id == ^w.a1.id) |> Ash.read!(authorize?: false)

      assert length(with_instance) == 1

      {:ok, _} = FourEyes.sign(w.tasks["ManagerSignoff"].id, :approved, as(w.team.manager))
      {:ok, applied} = FourEyes.sign(w.tasks["HeadVetSignoff"].id, :approved, as(w.team.head_vet))
      assert applied.disposition == :applied

      for appointment <- [w.a1, w.a2] do
        assert Instance
               |> Ash.Query.filter(subject_id == ^appointment.id)
               |> Ash.count!(authorize?: false) == 1

        assert HumanTask
               |> Ash.Query.filter(instance_id in ^Enum.map(with_instance_ids(appointment), & &1))
               |> Ash.count!(authorize?: false) >= 1
      end
    end

    test "an appointment with no instance gets one when its assignment is placed" do
      w = setup_week()

      # A visit booked before the process existed: seeded straight into the table, with no instance.
      orphan =
        Ash.Seed.seed!(ClinicDemo.Scheduling.Appointment, %{
          scheduled_at: DateTime.new!(w.monday, ~T[13:00:00], "Etc/UTC"),
          duration_minutes: 30,
          reason: "Legacy booking",
          status: :scheduled,
          severity: 2,
          patient_id: w.a1.patient_id,
          clinician_id: w.team.vet.id
        })

      assert Instance
             |> Ash.Query.filter(subject_id == ^orphan.id)
             |> Ash.count!(authorize?: false) == 0

      script = fn payload ->
        shifts = [{w.team.vet.id, 1, "early"}]
        ids = payload["ids"]["appointments"]
        {shifts, Enum.map(ids, &{&1, w.team.vet.id})}
      end

      {:ok, %{candidates: [candidate]}} = plan_fake(w.monday, staff(), script)
      assert candidate.check_status == :correct
      {:ok, _instance} = WeeklyRoster.submit_for_approval(candidate)
      tasks = FourEyes.tasks(candidate.id)
      {:ok, _} = FourEyes.sign(tasks["ManagerSignoff"].id, :approved, as(w.team.manager))
      {:ok, applied} = FourEyes.sign(tasks["HeadVetSignoff"].id, :approved, as(w.team.head_vet))
      assert applied.disposition == :applied

      assert Instance
             |> Ash.Query.filter(subject_id == ^orphan.id)
             |> Ash.count!(authorize?: false) == 1

      assert Instance |> Ash.Query.filter(subject_id == ^w.a1.id) |> Ash.count!(authorize?: false) ==
               1
    end
  end

  defp with_instance_ids(appointment) do
    Instance
    |> Ash.Query.filter(subject_id == ^appointment.id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
  end
end
