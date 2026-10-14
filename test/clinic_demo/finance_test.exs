defmodule ClinicDemo.FinanceTest do
  @moduledoc """
  The charge a completed visit recognizes: one per visit, amount
  snapshotted from the catalogue at completion, `recognized_at` at the
  write's own instant.

  These tests walk visits through the same back-dated lifecycle the seeds
  perform and interrogate the money the way the revenue view does — as-of
  reads over the temporal charges, so "what had the clinic recognized by
  instant T" behaves exactly like the board's time travel, pointed at
  money.
  """

  use ClinicDemo.DataCase, async: true

  require Ash.Query

  alias ClinicDemo.Finance
  alias ClinicDemo.Finance.Charge
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Scheduling.AppointmentType

  # A UUID, because booking starts a visit process and the instance records
  # who acted in uuid columns.
  @staff %{id: "00000000-0000-0000-0000-0000000000ee", role: :veterinarian}

  defp fixtures do
    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Finance Vet",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    {:ok, patient} =
      Scheduling.register_patient(
        %{
          name: "Ledger Animal",
          species: :cat,
          owner_email: "ledger-#{System.unique_integer([:positive])}@example.com"
        },
        actor: @staff
      )

    %{vet: vet, patient: patient}
  end

  defp catalogue_type(name \\ "Finance Test Visit", price \\ "175") do
    AppointmentType
    |> Ash.Changeset.for_create(:create, %{
      name: "#{name} #{System.unique_integer([:positive])}",
      base_price: Decimal.new(price),
      default_duration_minutes: 30
    })
    |> Ash.create!(authorize?: false)
  end

  defp hours_ago(hours),
    do: DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)

  # The seeds' walk, at test scale: book three hours back, check in one
  # hour back, write up half an hour back.
  defp back_dated_visit(patient, vet, type) do
    booked_at = hours_ago(3)
    checked_in_at = hours_ago(1)
    completed_at = hours_ago(1) |> DateTime.add(1800, :second)

    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          appointment_type_id: type && type.id,
          scheduled_at: hours_ago(1),
          duration_minutes: 30,
          reason: "Finance walk",
          severity: 2
        },
        actor: @staff,
        as_of: booked_at
      )

    Scheduling.check_in_appointment!(
      Scheduling.get_appointment!(appointment.id, as_of: checked_in_at),
      actor: @staff,
      as_of: checked_in_at
    )

    appointment =
      Scheduling.complete_appointment!(
        Scheduling.get_appointment!(appointment.id, as_of: completed_at),
        "Walked and written up",
        actor: @staff,
        as_of: completed_at
      )

    %{appointment: appointment, completed_at: completed_at}
  end

  test "a completed visit with a catalogue type recognizes its charge" do
    %{vet: vet, patient: patient} = fixtures()
    type = catalogue_type()

    %{appointment: appointment} = back_dated_visit(patient, vet, type)

    charge = Finance.charge_for(appointment.id)
    assert %Charge{} = charge
    assert Decimal.eq?(charge.amount, type.base_price)
    assert charge.status == :paid
    assert charge.appointment_id == appointment.id
  end

  test "recognized_at is the completion's own instant, not wall-now" do
    %{vet: vet, patient: patient} = fixtures()
    type = catalogue_type()

    %{appointment: appointment, completed_at: completed_at} = back_dated_visit(patient, vet, type)

    charge = Finance.charge_for(appointment.id)
    assert DateTime.compare(charge.recognized_at, completed_at) == :eq
  end

  test "a completed visit without a type recognizes nothing" do
    %{vet: vet, patient: patient} = fixtures()

    %{appointment: appointment} = back_dated_visit(patient, vet, nil)

    assert Finance.charge_for(appointment.id) == nil
  end

  test "one charge per visit, even across a temporal replay of :complete" do
    %{vet: vet, patient: patient} = fixtures()
    type = catalogue_type()

    %{appointment: appointment} = back_dated_visit(patient, vet, type)

    # The seeds' re-assert: walk :complete again at the present, exactly as
    # a resumed back-dated walk does. The clinic charges for the visit, not
    # for each retelling of it.
    open = Scheduling.get_appointment!(appointment.id)

    if open.status == :scheduled do
      open = Scheduling.check_in_appointment!(open, actor: @staff)
      Scheduling.complete_appointment!(open, "Re-asserted write-up", actor: @staff)
    end

    charges =
      Charge
      |> Ash.Query.filter(appointment_id == ^appointment.id)
      |> Ash.read!(authorize?: false)

    assert length(charges) == 1
  end

  test "the charge is a snapshot: repricing the catalogue does not move it" do
    %{vet: vet, patient: patient} = fixtures()
    type = catalogue_type()

    %{appointment: appointment} = back_dated_visit(patient, vet, type)

    type
    |> Ash.Changeset.for_update(:update, %{base_price: Decimal.new(999)})
    |> Ash.update!(authorize?: false)

    charge = Finance.charge_for(appointment.id)
    assert Decimal.eq?(charge.amount, Decimal.new(175))
  end

  test "revenue as of T is the containment read: nothing before the recognition, the charge after" do
    %{vet: vet, patient: patient} = fixtures()
    type = catalogue_type()

    %{appointment: appointment, completed_at: completed_at} = back_dated_visit(patient, vet, type)

    before =
      Charge
      |> Ash.read!(as_of: DateTime.add(completed_at, -60, :second), authorize?: false)

    refute Enum.any?(before, &(&1.appointment_id == appointment.id))

    after_recognition =
      Charge
      |> Ash.read!(as_of: DateTime.add(completed_at, 60, :second), authorize?: false)

    assert Enum.any?(
             after_recognition,
             &(&1.appointment_id == appointment.id and &1.status == :paid)
           )
  end

  test "revenue_by_month buckets the charge by its recognized_at month" do
    %{vet: vet, patient: patient} = fixtures()
    type = catalogue_type()

    %{appointment: appointment} = back_dated_visit(patient, vet, type)
    charge = Finance.charge_for(appointment.id)

    months = Finance.revenue_by_month(2)
    expected_month = charge.recognized_at |> DateTime.to_date() |> Date.beginning_of_month()

    row = Enum.find(months, &Date.equal?(&1.month, expected_month))
    assert row
    assert Decimal.eq?(row.total, type.base_price)
    assert row.count == 1
  end

  test "a written-off charge leaves the paid revenue" do
    %{vet: vet, patient: patient} = fixtures()
    type = catalogue_type()

    %{appointment: appointment} = back_dated_visit(patient, vet, type)
    charge = Finance.charge_for(appointment.id)

    {:ok, written_off} = Finance.write_off_charge(charge)
    assert written_off.status == :written_off

    months = Finance.revenue_by_month(2)

    assert Enum.all?(months, &Decimal.eq?(&1.total, Decimal.new(0)))
  end
end
