defmodule ClinicDemo.Planning.MobileExplainTest do
  @moduledoc """
  Why a mobile visit is refused, pure: the refusal diagnosis over a hand-written
  domain-level problem. Same map as the validator's: clinic - farm A 20 minutes,
  clinic - farm B 30, working hours 08:00-18:00.
  """

  use ExUnit.Case, async: true

  alias ClinicDemo.Planning.MobileExplain

  @clinic "00000000-0000-0000-0000-0000000000c0"
  @farm_a "00000000-0000-0000-0000-0000000000a1"
  @farm_b "00000000-0000-0000-0000-0000000000b1"
  @v1 "00000000-0000-0000-0000-000000000001"
  @morning "00000000-0000-0000-0000-0000000000f1"
  @afternoon "00000000-0000-0000-0000-0000000000f2"

  defp at(hhmm), do: "2026-11-09T#{hhmm}:00Z"

  defp visit(from, to, place, minutes \\ 30) do
    %{
      "id" => @v1,
      "window_from" => at(from),
      "window_to" => at(to),
      "booked_minutes" => minutes,
      "service_minutes" => minutes,
      "location_id" => place,
      "previous_starts_at" => nil
    }
  end

  defp commitment(id, from, to),
    do: %{"id" => id, "starts_at" => at(from), "ends_at" => at(to), "location_id" => @clinic}

  defp problem(visit, commitments, overrides \\ %{}) do
    travel =
      for {a, b, m} <- [{@clinic, @farm_a, 20}, {@clinic, @farm_b, 30}],
          {from, to} <- [{a, b}, {b, a}],
          do: %{"from" => from, "to" => to, "reachable" => true, "minutes" => m}

    Map.merge(
      %{
        "work_from" => at("08:00"),
        "work_to" => at("18:00"),
        "start_location_id" => @clinic,
        "end_location_id" => @clinic,
        "visits" => [visit],
        "commitments" => commitments,
        "blocked" => [],
        "travel" => travel
      },
      overrides
    )
  end

  defp refusal(problem), do: hd(MobileExplain.refusals(problem))

  test "a visit that fits its window but not the drive from an in-clinic commitment: travel_conflict, naming it" do
    problem = problem(visit("10:35", "11:05", @farm_a), [commitment(@morning, "10:00", "10:30")])

    assert %{reason: :travel_conflict, blocking: [@morning]} = refusal(problem)
  end

  test "a conflict with the commitment after names that one" do
    # Free calendar up to 10:00; the visit would end 09:50 but the clinic is 20 minutes away.
    problem =
      problem(visit("09:20", "09:50", @farm_a), [commitment(@afternoon, "10:00", "10:30")])

    assert %{reason: :travel_conflict, blocking: [@afternoon]} = refusal(problem)
  end

  test "with room for the drive the visit fits on its own" do
    problem = problem(visit("10:35", "11:35", @farm_a), [commitment(@morning, "10:00", "10:30")])
    assert %{reason: :fits_alone, blocking: []} = refusal(problem)
  end

  test "a window shorter than the service time is window_too_short" do
    assert %{reason: :window_too_short} = refusal(problem(visit("10:00", "10:20", @farm_a), []))
  end

  test "a window the calendar fills is no_free_time, not a travel problem" do
    problem = problem(visit("10:00", "10:30", @farm_a), [commitment(@morning, "09:45", "10:45")])
    assert %{reason: :no_free_time} = refusal(problem)

    outside_hours = problem(visit("17:45", "18:30", @farm_a), [])
    assert %{reason: :no_free_time} = refusal(outside_hours)
  end

  test "blocked time counts as no free time, and blocks the drive too" do
    blocked = [%{"id" => "lunch", "starts_at" => at("12:00"), "ends_at" => at("13:00")}]

    assert %{reason: :no_free_time} =
             refusal(problem(visit("12:00", "12:45", @farm_a), [], %{"blocked" => blocked}))

    # Service is clear of lunch but the 20-minute drive into it is not.
    assert %{reason: :travel_conflict} =
             refusal(problem(visit("13:00", "13:30", @farm_a), [], %{"blocked" => blocked}))
  end

  test "when every start the calendar allows needs an unreachable leg: unreachable" do
    travel = [
      %{"from" => @clinic, "to" => @farm_a, "reachable" => false, "minutes" => nil},
      %{"from" => @farm_a, "to" => @clinic, "reachable" => false, "minutes" => nil}
    ]

    assert %{reason: :unreachable} =
             refusal(problem(visit("10:00", "12:00", @farm_a), [], %{"travel" => travel}))
  end

  test "a pair the matrix does not hold is not free either" do
    assert %{reason: :travel_conflict} =
             refusal(problem(visit("10:00", "12:00", @farm_a), [], %{"travel" => []}))
  end
end
