defmodule ClinicDemoWeb.A2ui.AsOfSurfaceTest do
  @moduledoc """
  The board's as-of wire contract.

  `AsOfSurface.build/2` promises two things this test holds it to: the
  records on the wire are the versions valid at the instant (a card sits in
  the lane it was in then, and there is nothing on the wire from before the
  visit existed), and the surface is view-only (no invoke envelopes — the
  live surface's actions must not survive into a picture of the past).
  """

  use ClinicDemo.DataCase, async: true

  alias AshA2ui.Info
  alias ClinicDemo.Scheduling
  alias ClinicDemoWeb.A2ui.{AsOfSurface, BoardUI}

  @staff %{id: "00000000-0000-0000-0000-0000000000ee", role: :veterinarian}

  setup do
    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Wire Vet",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    {:ok, patient} =
      Scheduling.register_patient(
        %{
          name: "Lanewire Animal",
          species: :dog,
          owner_email: "lanewire-#{System.unique_integer([:positive])}@example.com"
        },
        actor: @staff
      )

    %{vet: vet, patient: patient}
  end

  defp hours_ago(hours),
    do: DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)

  # The invoke envelopes a live surface emits for its row actions — the
  # exact shape the basic composition builds:
  # %{"action" => %{"event" => %{"name" => "invoke", "context" => ...}}}.
  # Returns the invoked action names; the as-of surface must return none.
  defp invoked_actions(term, acc \\ [])

  defp invoked_actions(%{} = map, acc) do
    acc =
      case map do
        %{"action" => %{"event" => %{"name" => "invoke", "context" => %{"action" => name}}}} ->
          [name | acc]

        _ ->
          acc
      end

    Enum.reduce(map, acc, fn {_key, value}, acc -> invoked_actions(value, acc) end)
  end

  defp invoked_actions(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &invoked_actions/2)

  defp invoked_actions(_other, acc), do: acc

  # The lane tables of the root data model: %{"board_<lane>" => [records]}.
  defp lane_records(messages) do
    Enum.find_value(messages, fn
      %{"updateDataModel" => %{"path" => "/", "value" => %{"records" => records}}} ->
        records

      _ ->
        nil
    end) || %{}
  end

  # The lanes whose record lists carry the given appointment on the wire.
  defp record_lanes_for(messages, appointment_id) do
    messages
    |> lane_records()
    |> Enum.filter(fn {_lane, records} ->
      Enum.any?(records, &match?(%{"id" => ^appointment_id}, &1))
    end)
    |> Enum.map(fn {lane, _records} -> "/records/#{lane}" end)
  end

  test "the as-of surface is view-only where the live surface is operable", %{
    vet: vet,
    patient: patient
  } do
    Scheduling.book_appointment!(
      %{
        patient_id: patient.id,
        clinician_id: vet.id,
        scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
        reason: "Wire contract"
      },
      actor: @staff,
      as_of: hours_ago(1)
    )

    live_messages = Info.build_surface(BoardUI, actor: nil)
    assert invoked_actions(live_messages) != []

    as_of_messages = AsOfSurface.build(BoardUI, actor: nil, as_of: hours_ago(1))
    assert invoked_actions(as_of_messages) == []
  end

  test "cards sit in the lane they were in at the instant, and nowhere before", %{
    vet: vet,
    patient: patient
  } do
    booked_at = hours_ago(3)
    triaged_at = hours_ago(2)
    checked_in_at = hours_ago(1)

    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
          reason: "Lane history",
          # Severity 1 on an adult dog is the routine rule: the engine's
          # booking-time triage answers what the walk re-asserts, so the
          # back-dated write stays a re-assertion (one judgment recorded
          # once — see ClinicDemo.Scheduling.Changes.AdmitAcuityFact).
          severity: 1
        },
        actor: @staff,
        as_of: booked_at
      )

    # Before the booking: the lanes are all on the wire (the section set is
    # the board's shape, not its data) and none of them carries THIS visit.
    pre = AsOfSurface.build(BoardUI, actor: nil, as_of: DateTime.add(booked_at, -60))
    id = appointment.id

    # Every cell, on a database nobody seeded: the cells are board_lane's
    # declared stages crossed with triage_category's declared rows, not
    # rows of a table.
    cells =
      for row <- ~w(emergency urgent soon routine untriaged),
          stage <- ~w(booked in_visit discharged closed),
          do: "board_#{stage}__#{row}"

    assert lane_records(pre) |> Map.keys() |> Enum.sort() == Enum.sort(cells)

    assert Enum.all?(lane_records(pre), fn {_lane, records} ->
             not Enum.any?(records, &match?(%{"id" => ^id}, &1))
           end)

    # Booked but not yet triaged: the card is on the board, in the Booked
    # stage's untriaged row, rather than in no row at all.
    untriaged = AsOfSurface.build(BoardUI, actor: nil, as_of: DateTime.add(booked_at, 1800))
    assert record_lanes_for(untriaged, appointment.id) == ["/records/board_booked__untriaged"]

    Scheduling.record_appointment_triage!(
      Scheduling.get_appointment!(appointment.id, as_of: triaged_at),
      :routine,
      actor: @staff,
      as_of: triaged_at
    )

    # Between triage and check-in: one card, in the Booked stage's routine row.
    mid = AsOfSurface.build(BoardUI, actor: nil, as_of: hours_ago(2) |> DateTime.add(1800))
    assert record_lanes_for(mid, appointment.id) == ["/records/board_booked__routine"]

    Scheduling.check_in_appointment!(
      Scheduling.get_appointment!(appointment.id, as_of: checked_in_at),
      actor: @staff,
      as_of: checked_in_at
    )

    # After the check-in: the same card has moved to in_visit, in the same
    # row — and only there; the pre-triage and triaged instants keep their own reads.
    after_check_in = AsOfSurface.build(BoardUI, actor: nil, as_of: hours_ago(1))

    assert record_lanes_for(after_check_in, appointment.id) == [
             "/records/board_in_visit__routine"
           ]

    still_mid = AsOfSurface.build(BoardUI, actor: nil, as_of: hours_ago(2) |> DateTime.add(1800))
    assert record_lanes_for(still_mid, appointment.id) == ["/records/board_booked__routine"]
  end

  test "parse reads the picker's zone-less datetime-local value as UTC" do
    assert AsOfSurface.parse("2026-10-15T08:00") == {:ok, ~U[2026-10-15 08:00:00Z]}
    assert AsOfSurface.parse("2026-10-15T08:00:30") == {:ok, ~U[2026-10-15 08:00:30Z]}
    assert AsOfSurface.parse("2026-10-15T08:00:00Z") == {:ok, ~U[2026-10-15 08:00:00Z]}
    assert AsOfSurface.parse("2026-10-15") == :error
  end

  test "a past day's board holds that day's visits: the window follows the instant", %{
    vet: vet,
    patient: patient
  } do
    # A visit three days back, booked two days before its slot. The board
    # windows to the read instant's day and the next, so reading the morning
    # of the slot must show it. Windowed on the wall clock instead, the read
    # lands on today and tomorrow, where this visit never was.
    slot = DateTime.new!(Date.add(Date.utc_today(), -3), ~T[15:00:00], "Etc/UTC")

    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: slot,
          reason: "Past day window",
          severity: 1
        },
        actor: @staff,
        as_of: DateTime.add(slot, -2, :day)
      )

    morning_of = AsOfSurface.build(BoardUI, actor: nil, as_of: DateTime.add(slot, -6 * 3600))
    assert record_lanes_for(morning_of, appointment.id) != []
  end
end
