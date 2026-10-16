defmodule ClinicDemo.Visits.HumanTaskTest do
  @moduledoc """
  The worklist board's read and its three moves, exercised the way the a2ui
  host invokes them: as *generic* actions (`Ash.ActionInput.for_action(
  HumanTask, ...)` with the card's id injected as `:record_id`), not as
  updates on a loaded record.

  That shape matters — the completion's run block once piped `:record_id`
  into `Ash.get!/3` as the RESOURCE (the argument order is
  `Ash.get!(resource, id, opts)`), which raised inside the calling LiveView
  process: the surface's GenServer died and the browser remounted into
  "Surface clinic_worklist already exists" instead of showing anything.

  The moves run as the acting clinician, and `ClinicDemo.Visits.TaskDesk`
  refuses whoever the task is not for: a non-candidate cannot take an open
  task, and only the holder may complete or delegate a claimed one.
  """

  use ClinicDemo.DataCase, async: false

  require Ash.Query

  alias AshA2ui.Info
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Visits
  alias ClinicDemo.Visits.HumanTask
  alias ClinicDemo.Visits.Instance
  alias ClinicDemo.Visits.ProcessEvent

  @staff %{id: "00000000-0000-0000-0000-0000000000dd", role: :veterinarian}

  defp roster do
    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Task Vet",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    {:ok, nurse} =
      Scheduling.hire_clinician(%{full_name: "Task Nurse", role: :nurse}, actor: @staff)

    {:ok, other_nurse} =
      Scheduling.hire_clinician(
        %{
          full_name: "Second Nurse",
          role: :nurse,
          license_number: "RN-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    %{vet: vet, nurse: nurse, other_nurse: other_nurse}
  end

  defp book(vet) do
    {:ok, patient} =
      Scheduling.register_patient(
        %{name: "Task Animal", species: :dog, owner_email: unique_email()},
        actor: @staff
      )

    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
          reason: "Worklist drill"
        },
        actor: @staff
      )

    appointment
  end

  defp unique_email, do: "owner-#{System.unique_integer([:positive])}@example.com"

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

  # The ActionHandler's generic invocation: the resource plus a params map
  # whose :record_id names the row. The run block must fetch the task from
  # that id, not receive it as a record input.
  defp complete_task(task, outcome, actor_id, comment \\ nil) do
    HumanTask
    |> Ash.ActionInput.for_action(:complete_task, %{
      record_id: task.id,
      outcome: outcome,
      comment: comment
    })
    |> Ash.run_action(actor: %{id: actor_id})
  end

  defp run(action, params, actor) do
    HumanTask
    |> Ash.ActionInput.for_action(action, params)
    |> Ash.run_action(actor: actor)
  end

  defp worklist(actor) do
    [actor: actor] |> Visits.list_worklist!() |> Enum.map(&{&1.node_id, &1.status})
  end

  test "complete_task fetches the task from :record_id and routes the token" do
    %{vet: vet, nurse: nurse} = roster()
    appointment = book(vet)

    assert {:ok, _result} = complete_task(task_at(appointment, "CheckIn"), :arrived, nurse.id)

    # The engine advanced: the appointment checked in and the token moved on,
    # exactly as the engine facade path would have it.
    assert Scheduling.get_appointment!(appointment.id).status == :checked_in
    assert "Consult" in nodes_visited(appointment)
  end

  test "complete_task records the comment with the completion" do
    %{vet: vet, nurse: nurse} = roster()
    appointment = book(vet)

    assert {:ok, task} =
             complete_task(task_at(appointment, "CheckIn"), :arrived, nurse.id, "front desk")

    assert task.comment == "front desk"
  end

  test "complete_task without an actor is refused by the policy" do
    %{vet: vet} = roster()
    appointment = book(vet)

    assert {:error, %Ash.Error.Forbidden{}} =
             HumanTask
             |> Ash.ActionInput.for_action(:complete_task, %{
               record_id: task_at(appointment, "CheckIn").id,
               outcome: :arrived
             })
             |> Ash.run_action()
  end

  describe "the worklist read" do
    test "shows open tasks to their candidates and to nobody else" do
      %{vet: vet, nurse: nurse} = roster()
      book(vet)

      # CheckIn's candidates are the active nurses.
      assert worklist(nurse) == [{"CheckIn", :open}]
      assert worklist(vet) == []
      assert worklist(nil) == []
    end

    test "shows a claimed task to the clinician holding it" do
      %{vet: vet, nurse: nurse, other_nurse: other_nurse} = roster()
      appointment = book(vet)

      assert {:ok, %{status: :claimed}} =
               run(:claim_task, %{record_id: task_at(appointment, "CheckIn").id}, nurse)

      assert worklist(nurse) == [{"CheckIn", :claimed}]
      assert worklist(other_nurse) == []
    end

    test "puts each task in its lane on the board surface" do
      %{vet: vet, nurse: nurse} = roster()
      task = vet |> book() |> task_at("CheckIn")

      records =
        Info.build_surface(ClinicDemoWeb.A2ui.WorklistUI, actor: nurse)
        |> Enum.find_value(fn
          %{"updateDataModel" => %{"path" => "/", "value" => %{"records" => records}}} -> records
          _ -> nil
        end)

      assert Enum.map(records["board_open"], & &1["id"]) == [task.id]
      assert records["board_claimed"] == []
    end
  end

  describe "the board's moves" do
    test "a non-candidate cannot claim an open task" do
      %{vet: vet} = roster()
      appointment = book(vet)

      assert {:error, %Ash.Error.Forbidden{}} =
               run(:claim_task, %{record_id: task_at(appointment, "CheckIn").id}, vet)

      assert task_at(appointment, "CheckIn").status == :open
    end

    test "a non-candidate cannot complete an open task" do
      %{vet: vet} = roster()
      appointment = book(vet)

      assert {:error, %Ash.Error.Forbidden{}} =
               complete_task(task_at(appointment, "CheckIn"), :arrived, vet.id)

      assert Scheduling.get_appointment!(appointment.id).status == :scheduled
    end

    test "only the holder may complete a claimed task" do
      %{vet: vet, nurse: nurse, other_nurse: other_nurse} = roster()
      appointment = book(vet)
      task = task_at(appointment, "CheckIn")

      {:ok, _claimed} = run(:claim_task, %{record_id: task.id}, nurse)

      assert {:error, %Ash.Error.Forbidden{}} = complete_task(task, :arrived, other_nurse.id)
      assert {:ok, %{status: :completed}} = complete_task(task, :arrived, nurse.id)
      assert Scheduling.get_appointment!(appointment.id).status == :checked_in
    end

    test "the holder delegates by name; the colleague then holds the task" do
      %{vet: vet, nurse: nurse, other_nurse: other_nurse} = roster()
      task = vet |> book() |> task_at("CheckIn")

      {:ok, _claimed} = run(:claim_task, %{record_id: task.id}, nurse)

      assert {:ok, delegated} =
               run(:delegate_task, %{record_id: task.id, to: "  second NURSE "}, nurse)

      assert delegated.status == :claimed
      assert delegated.assignee_id == other_nurse.id
      assert delegated.delegated_from_id == nurse.id
      assert worklist(other_nurse) == [{"CheckIn", :claimed}]
      assert worklist(nurse) == []
    end

    test "delegation by licence number works too" do
      %{vet: vet, nurse: nurse, other_nurse: other_nurse} = roster()
      task = vet |> book() |> task_at("CheckIn")

      {:ok, _claimed} = run(:claim_task, %{record_id: task.id}, nurse)

      assert {:ok, %{assignee_id: assignee_id}} =
               run(:delegate_task, %{record_id: task.id, to: other_nurse.license_number}, nurse)

      assert assignee_id == other_nurse.id
    end

    test "delegation refuses a non-holder and an unknown colleague" do
      %{vet: vet, nurse: nurse, other_nurse: other_nurse} = roster()
      task = vet |> book() |> task_at("CheckIn")

      # Open, so nobody holds it yet.
      assert {:error, %Ash.Error.Forbidden{}} =
               run(:delegate_task, %{record_id: task.id, to: "Second Nurse"}, nurse)

      {:ok, _claimed} = run(:claim_task, %{record_id: task.id}, nurse)

      assert {:error, %Ash.Error.Forbidden{}} =
               run(:delegate_task, %{record_id: task.id, to: "Task Nurse"}, other_nurse)

      assert {:error, %Ash.Error.Invalid{} = error} =
               run(:delegate_task, %{record_id: task.id, to: "Nobody Here"}, nurse)

      assert Exception.message(error) =~ "no active clinician"
      assert task_at(task_instance_subject(task), "CheckIn").assignee_id == nurse.id
    end
  end

  defp task_instance_subject(task) do
    instance = Ash.get!(Instance, task.instance_id)
    Scheduling.get_appointment!(instance.subject_id)
  end
end
