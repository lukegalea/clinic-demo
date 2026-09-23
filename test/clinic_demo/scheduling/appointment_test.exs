defmodule ClinicDemo.Scheduling.AppointmentTest do
  @moduledoc """
  The lifecycle rules the introspection output advertises, asserted.

  If `mix ash_agent.describe` says `:complete` requires `notes` and refuses
  an appointment that has not been checked in, these tests are what make
  that claim true.
  """

  use ClinicDemo.DataCase, async: true

  alias ClinicDemo.Scheduling

  # A UUID, because booking starts a visit process and the instance records
  # who started it in a uuid column.
  @staff %{id: "00000000-0000-0000-0000-0000000000bb", role: :veterinarian}

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

  describe "the formal state machine" do
    test "completing from :scheduled is refused, naming the illegal transition" do
      %{appointment: appointment} = fixtures()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Scheduling.complete_appointment(appointment, "Notes long enough to pass",
                 actor: @staff
               )

      assert transition_error =
               Enum.find(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1))

      assert Exception.message(transition_error) =~ "from scheduled to completed"
      assert Scheduling.get_appointment!(appointment.id).status == :scheduled
    end

    test "cancelling works from both source states" do
      %{appointment: fresh} = fixtures()

      assert {:ok, cancelled} =
               Scheduling.cancel_appointment(fresh, "Owner called", actor: @staff)

      assert cancelled.status == :cancelled

      # And from :checked_in, the machine's other legal source.
      %{appointment: checked_in} = fixtures()
      {:ok, checked_in} = Scheduling.check_in_appointment(checked_in, actor: @staff)

      assert {:ok, cancelled_late} =
               Scheduling.cancel_appointment(checked_in, "Owner called", actor: @staff)

      assert cancelled_late.status == :cancelled
    end

    test "no_show is unreachable from anywhere but :scheduled" do
      %{appointment: appointment} = fixtures()
      {:ok, appointment} = Scheduling.check_in_appointment(appointment, actor: @staff)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Scheduling.mark_appointment_no_show(appointment, actor: @staff)

      assert Enum.any?(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1))
    end

    test "the derived chart describes the declared machine" do
      chart = ClinicDemo.Scheduling.VisitMachine.chart()

      assert chart =~ "stateDiagram-v2"
      assert chart =~ "scheduled --> checked_in: check_in"
      assert chart =~ "checked_in --> completed: complete"
      assert chart =~ "scheduled --> cancelled: cancel"
      assert chart =~ "checked_in --> cancelled: cancel"
      assert chart =~ "scheduled --> no_show: mark_no_show"
    end
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

  describe "booking with a nested new patient" do
    defp booking_attrs(vet, overrides) do
      Map.merge(
        %{
          clinician_id: vet.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
          reason: "New client, first visit"
        },
        overrides
      )
    end

    test "a patient map is registered on the spot and linked" do
      %{vet: vet} = fixtures()

      {:ok, appointment} =
        Scheduling.book_appointment(
          booking_attrs(vet, %{
            patient: %{name: "Waffle", species: :dog, owner_email: "waffle@example.com"}
          }),
          actor: @staff
        )

      assert appointment.patient_id
      patient = Ash.load!(appointment, [:patient]).patient
      assert patient.name == "Waffle"

      # The visit process still started and ran its triage — booking is
      # booking, whichever way the patient was named. (The engine's writes
      # land after the booking commits, so the record is re-read.)
      appointment = Scheduling.get_appointment!(appointment.id)
      assert appointment.triage_urgency
    end

    test "the nested create runs Patient.register's validations" do
      %{vet: vet} = fixtures()

      assert {:error, %Ash.Error.Invalid{}} =
               Scheduling.book_appointment(
                 booking_attrs(vet, %{
                   patient: %{name: "Waffle", species: :dog, owner_email: "not-an-email"}
                 }),
                 actor: @staff
               )
    end

    test "supplying both patient_id and patient is refused" do
      %{vet: vet, patient: patient} = fixtures()

      assert {:error, %Ash.Error.Invalid{}} =
               Scheduling.book_appointment(
                 booking_attrs(vet, %{
                   patient_id: patient.id,
                   patient: %{name: "Waffle", species: :dog, owner_email: "waffle@example.com"}
                 }),
                 actor: @staff
               )
    end

    test "supplying neither is refused" do
      %{vet: vet} = fixtures()

      assert {:error, %Ash.Error.Invalid{}} =
               Scheduling.book_appointment(booking_attrs(vet, %{}), actor: @staff)
    end
  end
end
