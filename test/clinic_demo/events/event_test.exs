defmodule ClinicDemo.Events.EventTest do
  @moduledoc """
  The audit resource IS the `ash_events` event log, and it cannot be written
  through a sanctioned path — an audit log with an application-facing write
  path is not an audit log. What it CAN be is appended to by the framework:
  every wrapped action on a story resource lands a row here, in the same
  transaction as its write.
  """

  use ClinicDemo.DataCase, async: true

  require Ash.Query

  alias Ash.Resource.Info
  alias ClinicDemo.Events.Event

  # Any signed-in staff member will do; the demo has no authentication.
  @staff %{id: "00000000-0000-0000-0000-0000000000aa", role: :veterinarian}

  test "story actions append to the log, with one row per write" do
    {:ok, vet} =
      ClinicDemo.Scheduling.hire_clinician(
        %{full_name: "Dr. Audit Probe", role: :veterinarian, license_number: "ON-900001"},
        actor: @staff
      )

    {:ok, patient} =
      ClinicDemo.Scheduling.register_patient(
        %{name: "Audit", species: :dog, owner_email: "audit.probe@example.com"},
        actor: @staff
      )

    {:ok, appointment} =
      ClinicDemo.Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: next_week(),
          duration_minutes: 15,
          reason: "Audit probe visit",
          severity: 2
        },
        actor: @staff
      )

    ClinicDemo.Scheduling.check_in_appointment!(appointment, actor: @staff)

    actions =
      Event
      |> Ash.Query.sort(:id)
      |> Ash.Query.load(:what)
      |> Ash.read!(authorize?: false)

    what = Enum.map(actions, & &1.what)

    assert "create on Elixir.ClinicDemo.Scheduling.Clinician" in what
    assert "register on Elixir.ClinicDemo.Scheduling.Patient" in what
    assert "book on Elixir.ClinicDemo.Scheduling.Appointment" in what
    assert "check_in on Elixir.ClinicDemo.Scheduling.Appointment" in what

    # The write and its event share one transaction: the row is attributed
    # to the action that caused it, with the story data alongside.
    book_event = Enum.find(actions, &(&1.action == :book))
    assert book_event.action_type == :create
    assert book_event.record_id == appointment.id
    assert %{"reason" => "Audit probe visit"} = book_event.data
  end

  test "the booking's triage decision leaves an evaluation event" do
    {:ok, vet} =
      ClinicDemo.Scheduling.hire_clinician(
        %{full_name: "Dr. Triage Probe", role: :veterinarian, license_number: "ON-900002"},
        actor: @staff
      )

    {:ok, patient} =
      ClinicDemo.Scheduling.register_patient(
        %{name: "Triage", species: :cat, owner_email: "triage.probe@example.com"},
        actor: @staff
      )

    # The rules are published once in test_helper, so booking starts the
    # visit process, which asks the triage decision and files an evaluation.
    {:ok, _appointment} =
      ClinicDemo.Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: next_week(),
          duration_minutes: 15,
          reason: "Triage probe visit",
          severity: 2
        },
        actor: @staff
      )

    evaluation_events =
      Event
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(resource == ClinicDemo.Decisions.Evaluation)
      |> Ash.read!(authorize?: false)

    assert [_ | _] = evaluation_events
    assert Enum.all?(evaluation_events, &(&1.action_type == :create))
  end

  test "the log is still not sanctionedly writable" do
    # ash_events' own machinery appends with authorize?: false inside the
    # writer's transaction; every authorized caller is refused, and the
    # log's :replay action matches no policy, so it is forbidden too.
    assert {:error, _} =
             Ash.create(
               Ash.Changeset.for_create(Event, :create, %{
                 record_id: Ecto.UUID.generate(),
                 resource: ClinicDemo.Scheduling.Appointment,
                 action: :book,
                 action_type: :create,
                 data: %{},
                 metadata: %{},
                 changed_attributes: %{}
               })
             )

    replay_action = Enum.find(Info.actions(Event), &(&1.name == :replay))
    assert replay_action

    assert {:error, _} = Ash.run_action(Ash.ActionInput.for_action(Event, :replay, %{}))
  end

  defp next_week do
    DateTime.utc_now()
    |> DateTime.add(7 * 24 * 60 * 60)
    |> DateTime.truncate(:second)
  end
end
