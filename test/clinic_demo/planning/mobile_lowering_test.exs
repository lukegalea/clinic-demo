defmodule ClinicDemo.Planning.MobileLoweringTest do
  @moduledoc """
  The model-lowering half of the mobile-visits plan, pure: facts to the model's minute
  data and the model's answer back to domain-level stops and legs. Everything about the
  grid (minutes after UTC midnight, half-open, inward rounding for windows and outward
  for pinned work, 1-based place indices, the flattened matrix, the trailing pad on
  arrays that can be empty) is pinned here, and only here: the validator has none of it.
  """

  use ExUnit.Case, async: true

  alias ClinicDemo.Planning.MobileLowering

  @day_start ~U[2026-11-09 00:00:00Z]
  @clinic "00000000-0000-0000-0000-0000000000c0"
  @farm_a "00000000-0000-0000-0000-0000000000a1"
  @farm_b "00000000-0000-0000-0000-0000000000b1"
  @v1 "00000000-0000-0000-0000-000000000001"
  @commitment "00000000-0000-0000-0000-0000000000f1"

  defp pairs(overrides \\ %{}) do
    Map.merge(
      %{
        {@clinic, @farm_a} => %{reachable: true, minutes: 20},
        {@farm_a, @clinic} => %{reachable: true, minutes: 20},
        {@clinic, @farm_b} => %{reachable: true, minutes: 30},
        {@farm_b, @clinic} => %{reachable: true, minutes: 30},
        {@farm_a, @farm_b} => %{reachable: true, minutes: 25},
        {@farm_b, @farm_a} => %{reachable: true, minutes: 25}
      },
      overrides
    )
  end

  defp visit(overrides \\ %{}) do
    Map.merge(
      %{
        id: @v1,
        window_from: ~U[2026-11-09 10:00:30Z],
        window_to: ~U[2026-11-09 12:00:30Z],
        service_minutes: 35,
        location_id: @farm_a,
        previous_starts_at: nil
      },
      overrides
    )
  end

  defp facts(overrides \\ %{}) do
    Map.merge(
      %{
        day: ~D[2026-11-09],
        effective_at: @day_start,
        start_location_id: @clinic,
        end_location_id: @clinic,
        involved_locations: Enum.sort([@clinic, @farm_a, @farm_b]),
        work_window: %{
          from: ~U[2026-11-09 08:00:00Z],
          to: ~U[2026-11-09 18:00:00Z],
          source: :default
        },
        visits: [visit()],
        commitments: [
          %{
            id: @commitment,
            starts_at: ~U[2026-11-09 09:00:00Z],
            ends_at: ~U[2026-11-09 09:30:30Z],
            location_id: @clinic
          }
        ],
        blocks: [
          %{id: "b1", starts_at: ~U[2026-11-09 12:30:30Z], ends_at: ~U[2026-11-09 13:00:30Z]}
        ],
        matrix: %{pairs: pairs()}
      },
      overrides
    )
  end

  defp data(overrides \\ %{}) do
    {:ok, %{"data" => data}} = MobileLowering.lower(facts(overrides))
    data
  end

  test "minutes after midnight: windows round inward, pinned work and blocked time outward" do
    data = data()

    # Window 10:00:30-12:00:30 becomes [10:01, 12:00): never wider than the exact window.
    assert Enum.take(data["v_from"], 1) == [10 * 60 + 1]
    assert Enum.take(data["v_to"], 1) == [12 * 60]
    # The service time is the booked time plus the access buffer, as the facts carry it.
    assert Enum.take(data["v_dur"], 1) == [35]
    # Commitment 09:00-09:30:30 becomes [540, 571): never narrower.
    assert Enum.take(data["c_from"], 1) == [9 * 60]
    assert Enum.take(data["c_to"], 1) == [9 * 60 + 31]
    # Blocked 12:30:30-13:00:30 becomes [750, 781).
    assert Enum.take(data["b_from"], 1) == [12 * 60 + 30]
    assert Enum.take(data["b_to"], 1) == [13 * 60 + 1]
    assert {data["work_from"], data["work_to"], data["horizon"]} == {480, 1080, 1440}
  end

  test "places are indexed 1.. in sorted id order and the matrix is flattened row-major" do
    {:ok, %{"data" => data, "ids" => ids}} = MobileLowering.lower(facts())

    assert ids["locations"] == Enum.sort([@clinic, @farm_a, @farm_b])
    clinic = Enum.find_index(ids["locations"], &(&1 == @clinic)) + 1
    a = Enum.find_index(ids["locations"], &(&1 == @farm_a)) + 1
    b = Enum.find_index(ids["locations"], &(&1 == @farm_b)) + 1

    assert data["n_loc"] == 3
    assert data["start_loc"] == clinic and data["end_loc"] == clinic
    assert Enum.take(data["v_loc"], 1) == [a]
    assert Enum.take(data["c_loc"], 1) == [clinic]

    cell = fn from, to -> (from - 1) * 3 + to - 1 end
    assert Enum.at(data["tt"], cell.(clinic, a)) == 20
    assert Enum.at(data["tt"], cell.(a, b)) == 25
    assert Enum.at(data["tt"], cell.(a, a)) == 0
    assert Enum.at(data["reach"], cell.(b, clinic))
    assert ids["visits"] == [@v1] and ids["commitments"] == [@commitment]
  end

  test "an unreachable pair is not reachable and costs a whole day, never zero" do
    data =
      data(%{matrix: %{pairs: pairs(%{{@clinic, @farm_a} => %{reachable: false, minutes: nil}})}})

    {:ok, %{"ids" => ids}} = MobileLowering.lower(facts())
    clinic = Enum.find_index(ids["locations"], &(&1 == @clinic)) + 1
    a = Enum.find_index(ids["locations"], &(&1 == @farm_a)) + 1
    cell = (clinic - 1) * 3 + a - 1

    refute Enum.at(data["reach"], cell)
    assert Enum.at(data["tt"], cell) == 1440
    # The other direction is its own pair.
    assert Enum.at(data["reach"], (a - 1) * 3 + clinic - 1)
  end

  test "a pair the matrix does not hold is an error, never a zero" do
    assert {:error, {:travel_pair_missing, from, to}} =
             MobileLowering.lower(
               facts(%{matrix: %{pairs: Map.delete(pairs(), {@farm_a, @farm_b})}})
             )

    assert {from, to} == {@farm_a, @farm_b}

    assert {:error, {:travel_pair_missing, _, _}} = MobileLowering.lower(facts(%{matrix: nil}))
  end

  test "a previously booked visit carries its start; an unbooked one -1" do
    assert Enum.take(data()["v_prev"], 1) == [-1]

    booked = data(%{visits: [visit(%{previous_starts_at: ~U[2026-11-09 10:30:00Z]})]})
    assert Enum.take(booked["v_prev"], 1) == [10 * 60 + 30]
  end

  test "every array that can be empty carries one trailing pad element" do
    data = data(%{visits: [], commitments: [], blocks: []})

    assert {data["n_visit"], data["n_commit"], data["n_block"]} == {0, 0, 0}

    for key <- ~w(v_from v_to v_dur v_loc v_prev c_from c_to c_loc b_from b_to) do
      assert [_pad] = data[key], "#{key} is padded"
    end
  end

  describe "decode" do
    defp payload do
      {:ok, lowered} = MobileLowering.lower(facts())

      problem = %{
        "day" => "2026-11-09",
        "visits" => [%{"id" => @v1, "booked_minutes" => 30}]
      }

      Map.put(lowered, "problem", problem)
    end

    test "reads the answer back to stops, the explicit legs and the end of the day" do
      # Nodes: 1 = the visit, 2 = the commitment, 3 = start of day, 4 = end of day.
      answer = %{
        "st" => [10 * 60 + 5, 9 * 60, 8 * 60, 10 * 60 + 5 + 35 + 20],
        "succ" => [4, 1, 2, 3],
        "tin" => [20, 0, 0, 20]
      }

      assert {:ok, decoded} = MobileLowering.decode(payload(), answer)

      assert [stop] = decoded["stops"]

      assert stop == %{
               "visit_request_id" => @v1,
               "starts_at" => "2026-11-09T10:05:00Z",
               "ends_at" => "2026-11-09T10:40:00Z",
               "booked_minutes" => 30,
               "service_minutes" => 35,
               "location_id" => @farm_a,
               "order" => 1
             }

      assert Enum.map(decoded["legs"], &{&1["from"], &1["to"]}) == [
               {"start", "appointment:#{@commitment}"},
               {"appointment:#{@commitment}", "visit_request:#{@v1}"},
               {"visit_request:#{@v1}", "end"}
             ]

      [_to_commitment, to_visit, home] = decoded["legs"]
      assert to_visit["minutes"] == 20
      assert to_visit["departs_at"] == "2026-11-09T09:45:00Z"
      assert to_visit["arrives_at"] == "2026-11-09T10:05:00Z"
      assert home["minutes"] == 20
      assert decoded["route_ends_at"] == "2026-11-09T11:00:00Z"
    end

    test "an answer that is not one route through every node is unreadable" do
      broken = %{"st" => [0, 0, 0, 0], "succ" => [1, 2, 3, 3], "tin" => [0, 0, 0, 0]}
      assert {:error, :answer_unreadable} = MobileLowering.decode(payload(), broken)

      short = %{"st" => [0], "succ" => [1], "tin" => [0]}
      assert {:error, :answer_unreadable} = MobileLowering.decode(payload(), short)
      assert {:error, :answer_unreadable} = MobileLowering.decode(payload(), %{})
    end
  end
end
