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

  # The board's lanes are seeded data (the board's shape changes with the
  # clinic's process, not with its data), so a migrated-not-seeded test
  # database has none and the sectioned table expands to nothing. Same rows,
  # same keys as the seeds.
  setup do
    for row <- [
          %{lane_key: "intake", label: "Booked", position: 1, accent: "neutral"},
          %{lane_key: "low", label: "Low — routine", position: 2, accent: "green"},
          %{lane_key: "medium", label: "Medium — soon", position: 3, accent: "amber"},
          %{lane_key: "high", label: "High — urgent & emergency", position: 4, accent: "red"},
          %{lane_key: "in_visit", label: "In visit", position: 5, accent: "violet"},
          %{lane_key: "discharged", label: "Discharged", position: 6, accent: "blue"},
          %{lane_key: "closed", label: "Closed", position: 7, accent: "neutral"}
        ] do
      ClinicDemo.Scheduling.BoardLane
      |> Ash.Changeset.for_create(:create, row)
      |> Ash.create!(authorize?: false)
    end

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
          reason: "Lane history"
        },
        actor: @staff,
        as_of: booked_at
      )

    # Before the booking: the lanes are all on the wire (the section set is
    # the board's shape, not its data) and none of them carries THIS visit.
    pre = AsOfSurface.build(BoardUI, actor: nil, as_of: DateTime.add(booked_at, -60))
    id = appointment.id

    assert lane_records(pre) != nil

    assert Enum.all?(lane_records(pre), fn {_lane, records} ->
             not Enum.any?(records, &match?(%{"id" => ^id}, &1))
           end)

    Scheduling.record_appointment_triage!(
      Scheduling.get_appointment!(appointment.id, as_of: triaged_at),
      :routine,
      actor: @staff,
      as_of: triaged_at
    )

    # Between booking and check-in: one card, in the low lane (routine).
    mid = AsOfSurface.build(BoardUI, actor: nil, as_of: hours_ago(2) |> DateTime.add(1800))
    assert record_lanes_for(mid, appointment.id) == ["/records/board_low"]

    Scheduling.check_in_appointment!(
      Scheduling.get_appointment!(appointment.id, as_of: checked_in_at),
      actor: @staff,
      as_of: checked_in_at
    )

    # After the check-in: the same card has moved to in_visit — and only
    # there; the pre-triage and triaged instants keep their own reads.
    after_check_in = AsOfSurface.build(BoardUI, actor: nil, as_of: hours_ago(1))
    assert record_lanes_for(after_check_in, appointment.id) == ["/records/board_in_visit"]

    still_mid = AsOfSurface.build(BoardUI, actor: nil, as_of: hours_ago(2) |> DateTime.add(1800))
    assert record_lanes_for(still_mid, appointment.id) == ["/records/board_low"]
  end
end
