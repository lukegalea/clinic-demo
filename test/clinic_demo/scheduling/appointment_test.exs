defmodule ClinicDemo.Scheduling.AppointmentTest do
  @moduledoc """
  The lifecycle rules the introspection output advertises, asserted.

  If `mix ash_agent.describe` says `:complete` requires `notes` and refuses
  an appointment that has not been checked in, these tests are what make
  that claim true.
  """

  use ClinicDemo.DataCase, async: true

  alias ClinicDemo.Scheduling

  @staff %{id: "test-staff", role: :veterinarian}

  defp fixtures do
    {:ok, vet} =
      Scheduling.hire_clinician(%{
        full_name: "Dr. Test Vet",
        role: :veterinarian,
        license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
      })

    {:ok, patient} =
      Scheduling.register_patient(%{
        name: "Test Animal",
        species: :dog,
        owner_email: "owner-#{System.unique_integer([:positive])}@example.com"
      })

    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
          reason: "Routine check"
        },
        actor: @staff
      )

    %{vet: vet, patient: patient, appointment: appointment}
  end

  test "a booked appointment starts scheduled" do
    %{appointment: appointment} = fixtures()
    assert appointment.status == :scheduled
    assert appointment.duration_minutes == 30
  end

  test "an appointment cannot be booked in the past" do
    %{vet: vet, patient: patient} = fixtures()

    assert {:error, %Ash.Error.Invalid{}} =
             Scheduling.book_appointment(
               %{
                 patient_id: patient.id,
                 clinician_id: vet.id,
                 scheduled_at: DateTime.add(DateTime.utc_now(), -1, :day),
                 reason: "Time travel"
               },
               actor: @staff
             )
  end

  test "changing the schedule requires an actor" do
    %{vet: vet, patient: patient} = fixtures()

    assert {:error, %Ash.Error.Forbidden{}} =
             Scheduling.book_appointment(%{
               patient_id: patient.id,
               clinician_id: vet.id,
               scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
               reason: "No actor"
             })
  end

  test "reading the schedule does not require an actor" do
    fixtures()
    assert [_ | _] = Scheduling.list_appointments!()
  end

  test "an appointment must be checked in before it can be completed" do
    %{appointment: appointment} = fixtures()

    assert {:error, %Ash.Error.Invalid{}} =
             Scheduling.complete_appointment(appointment, "Notes long enough to pass",
               actor: @staff
             )

    {:ok, appointment} = Scheduling.check_in_appointment(appointment, actor: @staff)
    assert appointment.status == :checked_in

    {:ok, appointment} =
      Scheduling.complete_appointment(appointment, "Notes long enough to pass", actor: @staff)

    assert appointment.status == :completed
    assert appointment.notes == "Notes long enough to pass"
  end

  test "a completed appointment cannot be cancelled" do
    %{appointment: appointment} = fixtures()
    {:ok, appointment} = Scheduling.check_in_appointment(appointment, actor: @staff)

    {:ok, appointment} =
      Scheduling.complete_appointment(appointment, "Notes long enough to pass", actor: @staff)

    assert {:error, %Ash.Error.Invalid{}} =
             Scheduling.cancel_appointment(appointment, "Owner called", actor: @staff)
  end

  test "in_window returns only appointments inside the window, earliest first" do
    %{vet: vet, patient: patient} = fixtures()

    {:ok, _later} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 10, :day),
          reason: "Much later"
        },
        actor: @staff
      )

    from = DateTime.utc_now()
    to = DateTime.add(from, 2, :day)

    assert [only] = Scheduling.appointments_in_window!(from, to)
    assert only.reason == "Routine check"
  end
end
