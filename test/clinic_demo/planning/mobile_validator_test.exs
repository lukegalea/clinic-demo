defmodule ClinicDemo.Planning.MobileValidatorTest do
  @moduledoc """
  The independent validator for `mobile_visits`, pure: a hand-written domain-level
  problem and hand-written stops, so every rule, and the code it fails with, is
  pinned without a model, a lowering or a database. The validator reads instants,
  minutes and place ids only.

  The map (minutes of driving, the same each way): clinic - farm A 20, clinic -
  farm B 30, farm A - farm B 25. Farm C is unreachable from farm A and unknown to the
  clinic. Working hours 08:00-18:00.
  """

  use ExUnit.Case, async: true

  alias ClinicDemo.Planning.MobileValidator

  @clinic "00000000-0000-0000-0000-0000000000c0"
  @farm_a "00000000-0000-0000-0000-0000000000a1"
  @farm_b "00000000-0000-0000-0000-0000000000b1"
  @farm_c "00000000-0000-0000-0000-0000000000c3"
  @v1 "00000000-0000-0000-0000-000000000001"
  @v2 "00000000-0000-0000-0000-000000000002"
  @commitment "00000000-0000-0000-0000-0000000000f1"

  defp at(hhmm), do: "2026-11-09T#{hhmm}:00Z"

  defp pair(from, to, minutes),
    do: %{"from" => from, "to" => to, "reachable" => true, "minutes" => minutes}

  defp travel do
    for {a, b, m} <- [{@clinic, @farm_a, 20}, {@clinic, @farm_b, 30}, {@farm_a, @farm_b, 25}],
        {from, to} <- [{a, b}, {b, a}],
        do: pair(from, to, m)
  end

  defp visit(id, from, to, place, minutes \\ 30) do
    %{
      "id" => id,
      "window_from" => at(from),
      "window_to" => at(to),
      "booked_minutes" => minutes,
      "service_minutes" => minutes,
      "location_id" => place,
      "previous_starts_at" => nil
    }
  end

  defp problem(visits, overrides \\ %{}) do
    Map.merge(
      %{
        "day" => "2026-11-09",
        "work_from" => at("08:00"),
        "work_to" => at("18:00"),
        "start_location_id" => @clinic,
        "end_location_id" => @clinic,
        "visits" => visits,
        "commitments" => [],
        "blocked" => [],
        "travel" => travel()
      },
      overrides
    )
  end

  defp stop(id, start, place, minutes \\ 30) do
    {:ok, starts_at, _} = DateTime.from_iso8601(at(start))
    ends_at = DateTime.add(starts_at, minutes * 60, :second)

    %{
      "visit_request_id" => id,
      "starts_at" => at(start),
      "ends_at" => DateTime.to_iso8601(ends_at),
      "booked_minutes" => minutes,
      "service_minutes" => minutes,
      "location_id" => place
    }
  end

  defp route(stops, ends), do: %{"stops" => stops, "legs" => [], "route_ends_at" => at(ends)}

  defp codes(:ok), do: []

  defp codes({:error, violations}),
    do: violations |> Enum.map(& &1.code) |> Enum.uniq() |> Enum.sort()

  test "a visit with room for the drive in and out is valid" do
    problem = problem([visit(@v1, "10:00", "12:00", @farm_a)])
    # Leave the clinic 08:00, arrive 08:20 (we start at 10:00), back at 10:50.
    assert :ok = MobileValidator.validate(problem, route([stop(@v1, "10:00", @farm_a)], "10:50"))
  end

  test "the same place needs no travel at all: two visits at one farm run back to back" do
    problem =
      problem([visit(@v1, "10:00", "12:00", @farm_a), visit(@v2, "10:00", "12:00", @farm_a)])

    assert :ok =
             MobileValidator.validate(
               problem,
               route([stop(@v1, "10:00", @farm_a), stop(@v2, "10:30", @farm_a)], "11:20")
             )
  end

  describe "every requested visit exactly once" do
    test "a visit left out, scheduled twice, or not requested" do
      problem = problem([visit(@v1, "10:00", "12:00", @farm_a)])

      assert [:visit_unaccounted] = codes(MobileValidator.validate(problem, route([], "08:00")))

      twice = route([stop(@v1, "10:00", @farm_a), stop(@v1, "11:00", @farm_a)], "11:50")
      assert :visit_double_scheduled in codes(MobileValidator.validate(problem, twice))

      stranger = route([stop(@v1, "10:00", @farm_a), stop(@v2, "11:00", @farm_a)], "11:50")
      assert :unknown_visit in codes(MobileValidator.validate(problem, stranger))
    end
  end

  describe "the stop itself" do
    test "before the window opens, or ending after it closes" do
      problem = problem([visit(@v1, "10:00", "11:00", @farm_a)])

      early = route([stop(@v1, "09:45", @farm_a)], "10:35")
      assert :outside_window in codes(MobileValidator.validate(problem, early))

      late = route([stop(@v1, "10:45", @farm_a)], "11:35")
      assert :outside_window in codes(MobileValidator.validate(problem, late))
    end

    test "at another place than requested, or for another length" do
      problem = problem([visit(@v1, "10:00", "12:00", @farm_a)])

      wrong_place = route([stop(@v1, "10:00", @farm_b)], "10:50")
      assert :wrong_location in codes(MobileValidator.validate(problem, wrong_place))

      short = route([stop(@v1, "10:00", @farm_a, 20)], "10:50")
      assert :stop_duration_mismatch in codes(MobileValidator.validate(problem, short))
    end
  end

  describe "travel is explicit" do
    defp with_commitment(visits) do
      problem(visits, %{
        "commitments" => [
          %{
            "id" => @commitment,
            "starts_at" => at("10:00"),
            "ends_at" => at("10:30"),
            "location_id" => @clinic
          }
        ]
      })
    end

    test "a visit that fits its window but not the drive from the commitment is refused" do
      problem = with_commitment([visit(@v1, "10:35", "11:05", @farm_a)])
      # 10:30 end + 20 minutes of driving = 10:50; the visit is placed at its window's start.
      squeezed = route([stop(@v1, "10:35", @farm_a)], "11:55")

      assert {:error, [violation]} = MobileValidator.validate(problem, squeezed)
      assert violation.code == :insufficient_travel
      assert violation.subject == "#{@commitment}->#{@v1}"
      assert violation.detail == %{needed_minutes: 20, available_minutes: 5}
    end

    test "the same visit with the drive between is valid" do
      problem = with_commitment([visit(@v1, "10:35", "11:35", @farm_a)])

      assert :ok =
               MobileValidator.validate(problem, route([stop(@v1, "10:50", @farm_a)], "11:40"))
    end

    test "the drive out to the next commitment counts too" do
      problem =
        problem([visit(@v1, "09:00", "10:00", @farm_a)], %{
          "commitments" => [
            %{
              "id" => @commitment,
              "starts_at" => at("10:00"),
              "ends_at" => at("10:30"),
              "location_id" => @clinic
            }
          ]
        })

      # Ends 09:50, the clinic is 20 minutes away: 10:10 is too late for 10:00.
      assert [:insufficient_travel] =
               codes(
                 MobileValidator.validate(problem, route([stop(@v1, "09:20", @farm_a)], "10:55"))
               )
    end

    test "the vet must be able to reach the first visit from the start of the day" do
      problem = problem([visit(@v1, "08:00", "09:00", @farm_a)])
      # Starts the day 08:00 at the clinic; farm A is 20 minutes away.
      assert [:insufficient_travel] =
               codes(
                 MobileValidator.validate(problem, route([stop(@v1, "08:05", @farm_a)], "08:55"))
               )
    end

    test "an unreachable pair is never usable, and an unknown pair is not zero" do
      unreachable =
        problem([visit(@v1, "10:00", "12:00", @farm_a)], %{
          "travel" =>
            Enum.map(travel(), fn
              %{"from" => @clinic, "to" => @farm_a} = p ->
                %{p | "reachable" => false, "minutes" => nil}

              p ->
                p
            end)
        })

      assert :unreachable_leg in codes(
               MobileValidator.validate(
                 unreachable,
                 route([stop(@v1, "10:00", @farm_a)], "10:50")
               )
             )

      unknown = problem([visit(@v1, "10:00", "12:00", @farm_c)])

      assert :travel_time_unknown in codes(
               MobileValidator.validate(unknown, route([stop(@v1, "10:00", @farm_c)], "10:50"))
             )
    end

    test "being back after working hours is refused" do
      problem = problem([visit(@v1, "17:00", "18:00", @farm_a)])
      # Ends 17:30, +20 minutes home: 17:50 is fine; 18:10 is not.
      assert :ok =
               MobileValidator.validate(problem, route([stop(@v1, "17:00", @farm_a)], "17:50"))

      assert :outside_work_hours in codes(
               MobileValidator.validate(problem, route([stop(@v1, "17:00", @farm_a)], "18:10"))
             )
    end
  end

  describe "the vet is in one place at a time" do
    test "a stop overlapping a pinned commitment" do
      problem =
        problem([visit(@v1, "10:00", "12:00", @clinic)], %{
          "commitments" => [
            %{
              "id" => @commitment,
              "starts_at" => at("10:00"),
              "ends_at" => at("10:30"),
              "location_id" => @clinic
            }
          ]
        })

      assert :overlap in codes(
               MobileValidator.validate(problem, route([stop(@v1, "10:15", @clinic)], "10:50"))
             )
    end

    test "two stops overlapping each other" do
      problem =
        problem([visit(@v1, "10:00", "12:00", @farm_a), visit(@v2, "10:00", "12:00", @farm_a)])

      assert :overlap in codes(
               MobileValidator.validate(
                 problem,
                 route([stop(@v1, "10:00", @farm_a), stop(@v2, "10:15", @farm_a)], "11:05")
               )
             )
    end
  end

  describe "blocked time" do
    defp with_block(visits) do
      problem(visits, %{
        "blocked" => [
          %{
            "id" => "lunch",
            "kind" => "unavailable",
            "starts_at" => at("12:00"),
            "ends_at" => at("13:00")
          }
        ]
      })
    end

    test "service inside blocked time" do
      problem = with_block([visit(@v1, "11:45", "13:30", @farm_a)])

      assert :in_blocked_time in codes(
               MobileValidator.validate(problem, route([stop(@v1, "11:45", @farm_a)], "12:35"))
             )
    end

    test "the drive inside blocked time, with the service itself clear of it" do
      problem = with_block([visit(@v1, "13:10", "14:00", @farm_a)])
      # Arrives 13:10 after leaving 12:50: the leg [12:50, 13:10) runs through lunch.
      assert [:travel_in_blocked_time] =
               codes(
                 MobileValidator.validate(problem, route([stop(@v1, "13:10", @farm_a)], "14:00"))
               )
    end

    test "service and drive clear of blocked time is valid" do
      problem = with_block([visit(@v1, "13:30", "14:30", @farm_a)])

      assert :ok =
               MobileValidator.validate(problem, route([stop(@v1, "13:30", @farm_a)], "14:20"))
    end
  end

  test "an unreadable route is a violation, not a crash" do
    problem = problem([visit(@v1, "10:00", "12:00", @farm_a)])

    assert [:route_unreadable] =
             codes(
               MobileValidator.validate(problem, %{"stops" => [], "route_ends_at" => "never"})
             )
  end
end
