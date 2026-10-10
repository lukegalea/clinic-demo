defmodule ClinicDemo.Scheduling.AppointmentTemporalTest do
  @moduledoc """
  The temporal contract the board's time travel stands on: a lifecycle
  written at spaced `as_of` instants reads back, at every instant, as the
  visit stood at that instant.

  These tests walk one appointment through the same back-dated writes the
  seeds perform — book three hours ago, triage two hours ago, check in one
  hour ago — and then interrogate the containment read at instants between
  the writes. If `?as_of=` on the board shows a card in the wrong lane for
  the wrong hour, the fault is here to find.
  """

  use ClinicDemo.DataCase, async: true

  require Ash.Query

  alias ClinicDemo.Scheduling
  alias ClinicDemo.Scheduling.Appointment

  # A UUID, because booking starts a visit process and the instance records
  # who started it in a uuid column.
  @staff %{id: "00000000-0000-0000-0000-0000000000dd", role: :veterinarian}

  defp fixtures do
    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Temporal Vet",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    {:ok, patient} =
      Scheduling.register_patient(
        %{
          name: "Chrono Animal",
          species: :dog,
          owner_email: "chrono-#{System.unique_integer([:positive])}@example.com"
        },
        actor: @staff
      )

    %{vet: vet, patient: patient}
  end

  defp hours_ago(hours),
    do: DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)

  defp lane(appointment) do
    appointment |> Ash.load!(:board_lane) |> Map.get(:board_lane)
  end

  test "a back-dated lifecycle reads back stage by stage" do
    %{vet: vet, patient: patient} = fixtures()

    booked_at = hours_ago(3)
    triaged_at = hours_ago(2)
    checked_in_at = hours_ago(1)

    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
          reason: "Temporal walk"
        },
        actor: @staff,
        as_of: booked_at
      )

    # Before the booking instant the visit did not exist: the containment
    # read finds nothing, not an empty shell. (The get's refusal surfaces
    # as the Invalid class carrying "record not found".)
    assert_raise Ash.Error.Invalid, fn ->
      Scheduling.get_appointment!(appointment.id, as_of: DateTime.add(booked_at, -60))
    end

    # As booked: scheduled and untriaged — the intake lane.
    as_booked = Scheduling.get_appointment!(appointment.id, as_of: booked_at)
    assert as_booked.status == :scheduled
    assert as_booked.triage_urgency == nil
    assert lane(as_booked) == "intake"

    # The engine's own triage write lands at wall-clock time (the process
    # engine is not temporal), so the history's triage is written the way
    # the seeds write it: subject fetched as of the write's instant.
    history = Scheduling.get_appointment!(appointment.id, as_of: triaged_at)

    Scheduling.record_appointment_triage!(history, :routine, actor: @staff, as_of: triaged_at)

    as_triaged = Scheduling.get_appointment!(appointment.id, as_of: triaged_at)
    assert as_triaged.status == :scheduled
    assert as_triaged.triage_urgency == :routine
    assert lane(as_triaged) == "low"

    # An instant BETWEEN the writes reads the earlier stage still.
    between =
      Scheduling.get_appointment!(appointment.id, as_of: hours_ago(2) |> DateTime.add(1800))

    assert between.status == :scheduled
    assert between.triage_urgency == :routine
    assert lane(between) == "low"

    Scheduling.check_in_appointment!(
      Scheduling.get_appointment!(appointment.id, as_of: checked_in_at),
      actor: @staff,
      as_of: checked_in_at
    )

    as_checked_in = Scheduling.get_appointment!(appointment.id, as_of: hours_ago(1))
    assert as_checked_in.status == :checked_in
    assert lane(as_checked_in) == "in_visit"

    # The present never regressed: the open version is the engine's
    # post-booking write, untouched by the back-dated walk.
    current = Scheduling.get_appointment!(appointment.id)
    assert current.status == :scheduled
  end

  test "every as-of read returns exactly one version" do
    %{vet: vet, patient: patient} = fixtures()

    booked_at = hours_ago(2)

    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
          reason: "One version per instant"
        },
        actor: @staff,
        as_of: booked_at
      )

    Scheduling.record_appointment_triage!(
      Scheduling.get_appointment!(appointment.id, as_of: hours_ago(1)),
      :urgent,
      actor: @staff,
      as_of: hours_ago(1)
    )

    # Two writes, many instants — each instant resolves to exactly one row.
    for minutes <- [0, 30, 60, 90, 119] do
      instant = DateTime.add(booked_at, minutes * 60)

      versions =
        Appointment
        |> Ash.Query.filter(id == ^appointment.id)
        |> Ash.read!(as_of: instant)

      assert length(versions) == 1
    end
  end

  test "NotInThePast measures the past from the write's instant" do
    %{vet: vet, patient: patient} = fixtures()

    # A slot two hours back is in the past of a write made now: refused,
    # exactly as the lifecycle always refused it.
    assert {:error, %Ash.Error.Invalid{}} =
             Scheduling.book_appointment(
               %{
                 patient_id: patient.id,
                 clinician_id: vet.id,
                 scheduled_at: hours_ago(2),
                 reason: "Slot in the real past"
               },
               actor: @staff
             )

    # The SAME slot is legal for a write made as of three hours ago: at
    # that instant the slot was in the visit's future. This is what lets
    # the seeded history book itself through the attributed actions.
    {:ok, _} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: hours_ago(2),
          reason: "Slot in the write's future"
        },
        actor: @staff,
        as_of: hours_ago(3)
      )
  end
end
