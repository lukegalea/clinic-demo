defmodule ClinicDemo.Visits.HumanTaskTest do
  @moduledoc """
  The worklist surface's row action, exercised the way the a2ui host invokes
  it: as a *generic* action (`Ash.ActionInput.for_action(HumanTask, ...)` with
  the row's id injected as `:record_id`), not as an update on a loaded record.

  That distinction is the whole point of this file — the action's run block
  used to pipe `:record_id` into `Ash.get!/3` as the RESOURCE (the argument
  order is `Ash.get!(resource, id, opts)`), which raised inside the calling
  LiveView process: the surface's GenServer died and the browser remounted
  into "Surface clinic_worklist already exists" instead of showing anything.
  """

  use ClinicDemo.DataCase, async: false

  require Ash.Query

  alias ClinicDemo.Scheduling
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

    %{vet: vet, nurse: nurse}
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
  defp a2ui_complete(task, outcome, actor_id, comment \\ nil) do
    HumanTask
    |> Ash.ActionInput.for_action(:a2ui_complete, %{
      record_id: task.id,
      outcome: outcome,
      comment: comment
    })
    |> Ash.run_action(actor: %{id: actor_id})
  end

  test "a2ui_complete fetches the task from :record_id and routes the token" do
    %{vet: vet, nurse: nurse} = roster()
    appointment = book(vet)

    assert {:ok, _result} = a2ui_complete(task_at(appointment, "CheckIn"), :arrived, nurse.id)

    # The engine advanced: the appointment checked in and the token moved on,
    # exactly as the engine facade path would have it.
    assert Scheduling.get_appointment!(appointment.id).status == :checked_in
    assert "Consult" in nodes_visited(appointment)
  end

  test "a2ui_complete records the comment with the completion" do
    %{vet: vet, nurse: nurse} = roster()
    appointment = book(vet)

    assert {:ok, task} =
             a2ui_complete(task_at(appointment, "CheckIn"), :arrived, nurse.id, "front desk")

    assert task.comment == "front desk"
  end

  test "a2ui_complete without an actor is refused by the policy" do
    %{vet: vet} = roster()
    appointment = book(vet)

    assert {:error, %Ash.Error.Forbidden{}} =
             HumanTask
             |> Ash.ActionInput.for_action(:a2ui_complete, %{
               record_id: task_at(appointment, "CheckIn").id,
               outcome: :arrived
             })
             |> Ash.run_action()
  end
end
