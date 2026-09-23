defmodule ClinicDemo.Visits.AppointmentVisitTest do
  @moduledoc """
  The visit process, walked.

  Four paths: straight through, the lab wait, the no-show, and the one that is
  refused. Nothing below reaches into the engine -- every step is a person
  completing the work item in front of them, or an ordinary Scheduling call.
  """

  use ClinicDemo.DataCase, async: false

  require Ash.Query

  alias ClinicDemo.Scheduling
  alias ClinicDemo.Visits.HumanTask
  alias ClinicDemo.Visits.Instance
  alias ClinicDemo.Visits.ProcessEvent

  @staff %{id: "00000000-0000-0000-0000-0000000000cc", role: :veterinarian}

  defp roster do
    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Test Vet",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    {:ok, nurse} =
      Scheduling.hire_clinician(%{full_name: "Test Nurse", role: :nurse}, actor: @staff)

    {:ok, tech} =
      Scheduling.hire_clinician(%{full_name: "Test Tech", role: :technician}, actor: @staff)

    %{vet: vet, nurse: nurse, tech: tech}
  end

  defp book(vet, opts) do
    {:ok, patient} =
      Scheduling.register_patient(
        Map.merge(
          %{
            name: "Test Animal",
            species: :dog,
            owner_email: "owner-#{System.unique_integer([:positive])}@example.com"
          },
          Keyword.get(opts, :patient, %{})
        ),
        actor: @staff
      )

    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
          reason: "Test visit",
          severity: Keyword.get(opts, :severity, 2)
        },
        actor: @staff
      )

    appointment
  end

  defp instance_for(appointment) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(subject_id == ^appointment.id)
    |> Ash.read_one!()
  end

  defp task_at(appointment, node_id) do
    instance = instance_for(appointment)

    HumanTask
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      instance_id == ^instance.id and node_id == ^node_id and status in [:open, :claimed]
    )
    |> Ash.read_one!()
  end

  defp nodes_visited(appointment) do
    instance = instance_for(appointment)

    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!()
    |> Enum.map(& &1.node_id)
  end

  defp reload(appointment), do: Scheduling.get_appointment!(appointment.id)

  describe "booking" do
    test "starts an instance pinned to the published process" do
      %{vet: vet} = roster()
      appointment = book(vet, [])

      instance = instance_for(appointment)
      assert instance.status == :running
      assert instance.subject_type == to_string(ClinicDemo.Scheduling.Appointment)
    end

    test "runs the triage decision and records what it answered" do
      %{vet: vet} = roster()

      appointment =
        book(vet, severity: 4, patient: %{name: "Ruby", species: :dog})

      assert reload(appointment).triage_urgency == :emergency
      assert "Triage" in nodes_visited(appointment)
      assert "AlertEmergencyTeam" in nodes_visited(appointment)
    end

    test "an ordinary urgency skips the emergency branch" do
      %{vet: vet} = roster()
      appointment = book(vet, severity: 1)

      assert reload(appointment).triage_urgency == :routine
      refute "AlertEmergencyTeam" in nodes_visited(appointment)
    end

    test "leaves the token waiting at check-in, on every nurse's list" do
      %{vet: vet, nurse: nurse} = roster()
      appointment = book(vet, [])

      task = task_at(appointment, "CheckIn")
      assert task.status == :open

      # Candidates are rows, so a task list is one indexed query rather than a
      # policy evaluated per task.
      assert task.id in my_task_ids(nurse)
      refute task.id in my_task_ids(vet)
    end
  end

  defp my_task_ids(clinician) do
    ClinicDemo.Visits
    |> AshBpmn.my_tasks(principal_ids: [clinician.id], actor: %{id: clinician.id})
    |> Enum.map(& &1.id)
  end

  describe "the happy path" do
    test "check in, see the patient, write it up, discharge" do
      %{vet: vet, nurse: nurse} = roster()
      appointment = book(vet, [])

      {:ok, _} =
        AshBpmn.complete_task(task_at(appointment, "CheckIn"),
          outcome: :arrived,
          actor: %{id: nurse.id}
        )

      assert reload(appointment).status == :checked_in

      # The vet writes the visit up through the ordinary action. The process
      # does not carry clinical text and never will -- a token carries routing.
      {:ok, _} =
        Scheduling.complete_appointment(
          reload(appointment),
          "Sound on all four. Nails trimmed.",
          actor: @staff
        )

      {:ok, _} =
        AshBpmn.complete_task(task_at(appointment, "Consult"),
          outcome: :written_up,
          actor: %{id: vet.id}
        )

      appointment = reload(appointment)
      assert appointment.status == :completed
      assert appointment.discharged_at

      instance = instance_for(appointment)
      assert instance.status == :completed
      assert instance.outcome == "discharged"

      refute "AwaitLabResults" in nodes_visited(appointment)
    end
  end

  describe "the wait path" do
    test "bloods sent parks the instance until the lab reports" do
      %{vet: vet, nurse: nurse, tech: tech} = roster()
      appointment = book(vet, [])

      {:ok, _} =
        AshBpmn.complete_task(task_at(appointment, "CheckIn"),
          outcome: :arrived,
          actor: %{id: nurse.id}
        )

      {:ok, _} =
        Scheduling.complete_appointment(
          reload(appointment),
          "Reduced gut sounds. Bloods sent.",
          actor: @staff
        )

      {:ok, _} =
        AshBpmn.complete_task(task_at(appointment, "Consult"),
          outcome: :labs_pending,
          actor: %{id: vet.id}
        )

      # This is the wait. The token has stopped on a row; nothing is polling.
      waiting = task_at(appointment, "AwaitLabResults")
      assert waiting.status == :open
      assert instance_for(appointment).status == :running
      refute reload(appointment).discharged_at

      {:ok, _} = AshBpmn.complete_task(waiting, outcome: :results_in, actor: %{id: tech.id})

      assert reload(appointment).discharged_at
      assert instance_for(appointment).status == :completed
      assert instance_for(appointment).outcome == "discharged"
    end

    test "the lab task is offered to technicians, not to the booked vet" do
      %{vet: vet, nurse: nurse, tech: tech} = roster()
      appointment = book(vet, [])

      {:ok, _} =
        AshBpmn.complete_task(task_at(appointment, "CheckIn"),
          outcome: :arrived,
          actor: %{id: nurse.id}
        )

      {:ok, _} =
        Scheduling.complete_appointment(reload(appointment), "Bloods sent.", actor: @staff)

      {:ok, _} =
        AshBpmn.complete_task(task_at(appointment, "Consult"),
          outcome: :labs_pending,
          actor: %{id: vet.id}
        )

      lab_task = task_at(appointment, "AwaitLabResults")
      assert lab_task.id in my_task_ids(tech)
      refute lab_task.id in my_task_ids(vet)
    end
  end

  describe "the no-show path" do
    test "ends the instance and marks the appointment" do
      %{vet: vet, nurse: nurse} = roster()
      appointment = book(vet, [])

      {:ok, _} =
        AshBpmn.complete_task(task_at(appointment, "CheckIn"),
          outcome: :no_show,
          actor: %{id: nurse.id}
        )

      assert reload(appointment).status == :no_show
      assert instance_for(appointment).outcome == "no_show"
      refute reload(appointment).discharged_at
    end
  end

  describe "the process is guarded like every other caller" do
    test "discharging a visit nobody wrote up fails the instance" do
      %{vet: vet, nurse: nurse} = roster()
      appointment = book(vet, [])

      {:ok, _} =
        AshBpmn.complete_task(task_at(appointment, "CheckIn"),
          outcome: :arrived,
          actor: %{id: nurse.id}
        )

      # No `complete_appointment` call: the notes were never written. The
      # `:discharge` action refuses, and the process is refused with it.
      assert_raise Ash.Error.Invalid, fn ->
        AshBpmn.complete_task!(task_at(appointment, "Consult"),
          outcome: :written_up,
          actor: %{id: vet.id}
        )
      end

      appointment = reload(appointment)
      assert appointment.status == :checked_in
      refute appointment.discharged_at
    end
  end
end
