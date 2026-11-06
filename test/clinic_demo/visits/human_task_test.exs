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

  The moves run as the acting clinician through `ClinicDemo.Visits.TaskDesk`,
  and the engine refuses whoever the task is not for: a non-candidate cannot
  take an open task, only the holder may complete or delegate a claimed one,
  and only to another candidate. TaskDesk turns those refusals into errors
  the surface can show, and adds the clinic's own checks: the outcome is one
  the step declares, and the delegate is an active colleague.
  """

  use ClinicDemo.DataCase, async: false

  require Ash.Query

  alias AshA2ui.Info
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Visits
  alias ClinicDemo.Visits.Calculations.OutcomeChoices
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

      records = board_records(nurse)

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

    test "the holder delegates to a colleague; the colleague then holds the task" do
      %{vet: vet, nurse: nurse, other_nurse: other_nurse} = roster()
      task = vet |> book() |> task_at("CheckIn")

      {:ok, _claimed} = run(:claim_task, %{record_id: task.id}, nurse)

      assert {:ok, delegated} =
               run(:delegate_task, %{record_id: task.id, delegate_id: other_nurse.id}, nurse)

      assert delegated.status == :claimed
      assert delegated.assignee_id == other_nurse.id
      assert delegated.delegated_from_id == nurse.id
      assert worklist(other_nurse) == [{"CheckIn", :claimed}]
      assert worklist(nurse) == []
    end

    test "delegation refuses a non-holder" do
      %{vet: vet, nurse: nurse, other_nurse: other_nurse} = roster()
      task = vet |> book() |> task_at("CheckIn")

      # Open, so nobody holds it yet: the engine's delegate action refuses it.
      assert {:error, %Ash.Error.Invalid{} = error} =
               run(:delegate_task, %{record_id: task.id, delegate_id: other_nurse.id}, nurse)

      assert Exception.message(error) =~ "task must be claimed"

      {:ok, _claimed} = run(:claim_task, %{record_id: task.id}, nurse)

      assert {:error, %Ash.Error.Forbidden{}} =
               run(:delegate_task, %{record_id: task.id, delegate_id: nurse.id}, other_nurse)

      assert task_at(task_instance_subject(task), "CheckIn").assignee_id == nurse.id
    end

    test "delegation refuses the holder themself, an inactive clinician and a non-candidate" do
      %{vet: vet, nurse: nurse, other_nurse: other_nurse} = roster()
      task = vet |> book() |> task_at("CheckIn")

      {:ok, _claimed} = run(:claim_task, %{record_id: task.id}, nurse)

      assert delegate_error(task, nurse.id, nurse) =~ "is you"

      {:ok, _retired} = Scheduling.retire_clinician(other_nurse, actor: @staff)
      assert delegate_error(task, other_nurse.id, nurse) =~ "is not an active clinician"
      assert delegate_error(task, Ecto.UUID.generate(), nurse) =~ "is not an active clinician"

      # The vet is active, but CheckIn's candidates are the nurses: the engine
      # refuses, and the refusal lands on the picker.
      assert delegate_error(task, vet.id, nurse) =~ "is not one of this task's candidates"

      assert task_at(task_instance_subject(task), "CheckIn").assignee_id == nurse.id
    end
  end

  describe "outcomes" do
    test "a completion takes only an outcome its step declares" do
      %{vet: vet, nurse: nurse} = roster()
      appointment = book(vet)
      task = task_at(appointment, "CheckIn")

      assert Ash.load!(task, :outcomes).outcomes == ["arrived", "no_show"]

      # An outcome the Arrived? gateway does not name would take its default
      # flow and mark the visit a no-show; it is refused before the engine.
      assert {:error, %Ash.Error.Invalid{} = error} = complete_task(task, :written_up, nurse.id)
      assert Exception.message(error) =~ "choose Arrived or No show"

      assert task_at(appointment, "CheckIn").status == :open
      assert Scheduling.get_appointment!(appointment.id).status == :scheduled
    end

    test "each step's Complete action offers exactly the outcomes its step declares" do
      graph =
        "priv/processes/appointment_visit.bpmn"
        |> File.read!()
        |> AshBpmn.Compiler.compile!()

      for {action, node_id} <- [
            complete_check_in: "CheckIn",
            complete_consult: "Consult",
            complete_lab_results: "AwaitLabResults"
          ] do
        offered =
          HumanTask
          |> Ash.Resource.Info.action(action)
          |> Map.fetch!(:arguments)
          |> Enum.find(&(&1.name == :outcome))
          |> Map.fetch!(:constraints)
          |> Keyword.fetch!(:one_of)
          |> Enum.map(&to_string/1)

        assert offered == graph["nodes"][node_id]["outcomes"], "#{action} vs #{node_id}"
      end
    end

    test "a step's Complete action routes the token like the general one" do
      %{vet: vet, nurse: nurse} = roster()
      appointment = book(vet)
      task = task_at(appointment, "CheckIn")

      assert {:ok, %{status: :completed}} =
               run(:complete_check_in, %{record_id: task.id, outcome: :arrived}, nurse)

      assert Scheduling.get_appointment!(appointment.id).status == :checked_in
      assert task_at(appointment, "Consult")
    end

    test "a step's Complete action refuses another step's task" do
      %{vet: vet, nurse: nurse} = roster()
      appointment = book(vet)
      task = task_at(appointment, "CheckIn")

      # :written_up is :complete_consult's; on a CheckIn task the step's own
      # outcomes decide, so the visit is not routed down a default flow.
      assert {:error, %Ash.Error.Invalid{}} =
               run(:complete_consult, %{record_id: task.id, outcome: :written_up}, nurse)

      assert task_at(appointment, "CheckIn").status == :open
    end

    test "a board card offers only its own step's Complete" do
      %{vet: vet, nurse: nurse} = roster()
      task = vet |> book() |> task_at("CheckIn")

      [card] = board_records(nurse)["board_open"]
      assert card["id"] == task.id
      assert card["_actions"] == ["claim_task", "complete_check_in"]
    end

    test "the outcomes read as a phrase" do
      assert OutcomeChoices.phrase(["results_in"]) == "Results in"
      assert OutcomeChoices.phrase(["arrived", "no_show"]) == "Arrived or No show"
      assert OutcomeChoices.phrase(["a", "b", "c_d"]) == "A, B or C d"
      assert OutcomeChoices.phrase(nil) == nil
    end

    test "the board's cards show their step's outcomes" do
      %{vet: vet, nurse: nurse} = roster()
      task = vet |> book() |> task_at("CheckIn")

      [card] = board_records(nurse)["board_open"]

      assert card["id"] == task.id
      assert card["outcome_choices"] == "Arrived or No show"
    end
  end

  describe "counts" do
    # Ash.count/2 skips before_action hooks, which is where the engine's
    # :awaiting_actor narrows; the board's lane totals are counts.
    test "the worklist counts only the actor's tasks" do
      %{vet: vet, nurse: nurse} = roster()
      vet |> book() |> task_at("CheckIn")
      vet |> book() |> task_at("CheckIn")

      for {actor, expected} <- [{nurse, 2}, {vet, 0}] do
        query = Ash.Query.for_read(HumanTask, :worklist, %{}, actor: actor)
        assert length(Ash.read!(query)) == expected
        assert Ash.count!(query) == expected
      end
    end

    test "the board's lane totals are the actor's" do
      %{vet: vet, nurse: nurse} = roster()
      vet |> book() |> task_at("CheckIn")
      vet |> book() |> task_at("CheckIn")

      assert lane_totals(nurse) == %{"open" => "2", "claimed" => "0"}
      assert lane_totals(vet) == %{"open" => "0", "claimed" => "0"}
    end
  end

  defp lane_totals(actor) do
    Info.build_surface(ClinicDemoWeb.A2ui.WorklistUI, actor: actor)
    |> Enum.find_value(fn
      %{"updateDataModel" => %{"path" => "/", "value" => value}} -> value
      _ -> nil
    end)
    |> Enum.flat_map(fn
      {"_lane_total_board_" <> lane, total} -> [{lane, total}]
      _other -> []
    end)
    |> Map.new()
  end

  defp delegate_error(task, delegate_id, actor) do
    assert {:error, %Ash.Error.Invalid{} = error} =
             run(:delegate_task, %{record_id: task.id, delegate_id: delegate_id}, actor)

    Exception.message(error)
  end

  defp board_records(actor) do
    Info.build_surface(ClinicDemoWeb.A2ui.WorklistUI, actor: actor)
    |> Enum.find_value(fn
      %{"updateDataModel" => %{"path" => "/", "value" => %{"records" => records}}} -> records
      _ -> nil
    end)
  end

  defp task_instance_subject(task) do
    instance = Ash.get!(Instance, task.instance_id)
    Scheduling.get_appointment!(instance.subject_id)
  end
end
