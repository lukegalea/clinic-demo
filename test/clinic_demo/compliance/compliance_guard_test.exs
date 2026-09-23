defmodule ClinicDemo.Compliance.ComplianceGuardTest do
  @moduledoc """
  The compliance guard on the appointment state machine, with the rule bundle
  activated.

  Everything here runs against the *activated bundle*, not the module: the
  lifecycle in `ClinicDemo.Compliance.activate_appointment_bundle!/1` is what
  the seeds run, so these tests assert the same rules a real operator's
  transitions would meet.
  """

  use ClinicDemo.DataCase, async: true

  alias ClinicDemo.Compliance
  alias ClinicDemo.Repo
  alias ClinicDemo.Scheduling

  # A UUID, because the guard's audit row attributes the decision to the actor.
  @staff %{id: "00000000-0000-0000-0000-0000000000cc", role: :veterinarian}

  setup do
    Compliance.activate_appointment_bundle!()
    :ok
  end

  defp fixtures do
    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Compliance Vet",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    {:ok, patient} =
      Scheduling.register_patient(
        %{
          name: "Unweighed Animal",
          species: :dog,
          owner_email: "owner-#{System.unique_integer([:positive])}@example.com"
        },
        actor: @staff
      )

    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
          reason: "Torn nail"
        },
        actor: @staff
      )

    %{vet: vet, patient: patient, appointment: appointment}
  end

  test "check_in is refused while the patient has no recorded weight" do
    %{appointment: appointment} = fixtures()

    result = Scheduling.check_in_appointment(appointment, actor: @staff)
    assert {:error, error} = result

    message = Exception.message(error)
    assert message =~ "appt.checkin_requires_weight"
    assert message =~ "record the patient's weight before check-in"
  end

  test "check_in passes once the weight is recorded" do
    %{patient: patient, appointment: appointment} = fixtures()

    {:ok, _} = Scheduling.record_weight(patient, Decimal.new("12.5"), actor: @staff)

    assert {:ok, checked_in} = Scheduling.check_in_appointment(appointment, actor: @staff)
    assert checked_in.status == :checked_in
  end

  test "a passing transition records a compliance evaluation" do
    %{patient: patient, appointment: appointment} = fixtures()

    {:ok, _} = Scheduling.record_weight(patient, Decimal.new("12.5"), actor: @staff)
    {:ok, checked_in} = Scheduling.check_in_appointment(appointment, actor: @staff)

    assert [evaluation] =
             AshCompliance.Domain.evaluations_for_subject!(
               Compliance.organization_id(),
               "appointment",
               checked_in.id,
               authorize?: false
             )

    assert evaluation.outcome == :compliant
    assert evaluation.subject_id == checked_in.id
    assert "appt.checkin_requires_weight" in evaluation.rule_ids
    assert evaluation.source_event_id == @staff.id
  end

  test "completion is refused when the triage decision never answered" do
    %{patient: patient, appointment: appointment} = fixtures()

    {:ok, _} = Scheduling.record_weight(patient, Decimal.new("12.5"), actor: @staff)

    # Fresh reads, as every real caller would: the visit process writes the
    # triage answer shortly after booking, and a struct captured before that
    # would understate the record's state.
    checked_in =
      case Scheduling.check_in_appointment(Scheduling.get_appointment!(appointment.id),
             actor: @staff
           ) do
        {:ok, checked_in} -> checked_in
      end

    # Simulate a booking that raced past triage: the state the rule exists to
    # catch cannot be produced through the public API, because the visit
    # process runs the decision before the row lands.
    Repo.update_all(
      from(a in Scheduling.Appointment, where: a.id == ^checked_in.id),
      set: [triage_urgency: nil]
    )

    checked_in = Scheduling.get_appointment!(checked_in.id)

    result =
      Scheduling.complete_appointment(checked_in, "Notes long enough to pass", actor: @staff)

    assert {:error, error} = result
    assert Exception.message(error) =~ "appt.complete_requires_triage"
  end

  test "completion passes with triage urgency and notes" do
    %{patient: patient, appointment: appointment} = fixtures()

    {:ok, _} = Scheduling.record_weight(patient, Decimal.new("12.5"), actor: @staff)

    {:ok, checked_in} =
      Scheduling.check_in_appointment(Scheduling.get_appointment!(appointment.id),
        actor: @staff
      )

    checked_in = Scheduling.get_appointment!(checked_in.id)

    assert {:ok, completed} =
             Scheduling.complete_appointment(checked_in, "Notes long enough to pass",
               actor: @staff
             )

    assert completed.status == :completed
  end

  test "cancellation is guarded but nothing forbids it" do
    %{appointment: appointment} = fixtures()

    # No weight on record is irrelevant to :cancelled — the weight rule's
    # applicability clause scopes it to :checked_in.
    assert {:ok, cancelled} =
             Scheduling.cancel_appointment(appointment, "Owner called", actor: @staff)

    assert cancelled.status == :cancelled
  end
end

defmodule ClinicDemo.Compliance.ComplianceGuardNoBundleTest do
  @moduledoc """
  The guard's inert path: with no active policy bundle, transitions behave
  exactly as they did before compliance existed. This is the state a fresh
  checkout is in.
  """

  use ClinicDemo.DataCase, async: true

  alias ClinicDemo.Scheduling

  @staff %{id: "00000000-0000-0000-0000-0000000000cd", role: :veterinarian}

  test "check_in succeeds without a recorded weight when no bundle is active" do
    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Pre-Seed",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    {:ok, patient} =
      Scheduling.register_patient(
        %{
          name: "Unweighed Animal",
          species: :dog,
          owner_email: "owner-#{System.unique_integer([:positive])}@example.com"
        },
        actor: @staff
      )

    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
          reason: "Torn nail"
        },
        actor: @staff
      )

    assert {:ok, checked_in} = Scheduling.check_in_appointment(appointment, actor: @staff)
    assert checked_in.status == :checked_in
  end
end
