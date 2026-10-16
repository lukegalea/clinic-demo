defmodule ClinicDemo.BusinessEventsDrainerTest do
  @moduledoc """
  The live fold: a moment written through the publish bridge reaches the
  value projection without anyone calling drain, and the drainer says so
  on its topic. `async: false` because the drainer is its own process and
  reads through the shared sandbox.

  The advisory lock that serializes drains is not provable here: under the
  sandbox every process shares one connection, and Postgres advisory locks
  are re-entrant per session.
  """

  use ClinicDemo.DataCase, async: false

  require Ash.Query

  alias ClinicDemo.BusinessEvents.ValueDrainer
  alias ClinicDemo.BusinessEvents.ValueProjection
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Scheduling.AppointmentType

  @staff %{id: "00000000-0000-0000-0000-0000000000d8", role: :veterinarian}

  setup do
    ClinicDemo.BusinessEvents.install!()

    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Drain Test",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    {:ok, patient} =
      Scheduling.register_patient(
        %{
          name: "Drain Test Animal",
          species: :dog,
          owner_email: "drain-#{System.unique_integer([:positive])}@example.com"
        },
        actor: @staff
      )

    type =
      AppointmentType
      |> Ash.Changeset.for_create(:create, %{
        name: "Drain Test Exam #{System.unique_integer([:positive])}",
        base_price: Decimal.new(120),
        default_duration_minutes: 30
      })
      |> Ash.create!(authorize?: false)

    %{vet: vet, patient: patient, type: type}
  end

  test "a completed visit folds without an explicit drain, and the fold is announced", world do
    start_supervised!(ValueDrainer)
    Phoenix.PubSub.subscribe(ClinicDemo.PubSub, ValueDrainer.topic())

    appointment = complete_visit(world)

    assert_receive {:value_projection_drained, count} when count > 0, 5_000

    row =
      ValueProjection
      |> Ash.Query.filter(subject == ^appointment.id)
      |> Ash.read_one!(authorize?: false)

    assert row.outcome == :completed
    assert Decimal.eq?(row.recognized_amount, Decimal.new(120))

    # Nothing is left behind the checkpoint.
    assert ValueDrainer.drain() == 0
  end

  test "drain/0 folds what is pending once, then has nothing to do", world do
    complete_visit(world)

    assert ValueDrainer.drain() > 0
    assert ValueDrainer.drain() == 0
  end

  defp complete_visit(%{vet: vet, patient: patient, type: type}) do
    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          appointment_type_id: type.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
          duration_minutes: type.default_duration_minutes,
          reason: "Drain walk",
          severity: 2
        },
        actor: @staff
      )

    appointment = Scheduling.check_in_appointment!(appointment, actor: @staff)
    Scheduling.complete_appointment!(appointment, "Written up for the fold", actor: @staff)
  end
end
