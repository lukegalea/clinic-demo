defmodule ClinicDemo.Planning.LoweringTest do
  @moduledoc """
  The model-lowering half of the roster, pure: facts to the model's slot data and
  the model's answer back to domain-level assignments. Everything about the grid
  (15-minute slots, absolute within the week, half-open, role codes, 1-based
  indices, trailing pad on arrays that can be empty) is pinned here, and only here:
  the validator has none of it.
  """

  use ExUnit.Case, async: true

  alias ClinicDemo.Planning.Lowering

  @monday ~U[2026-11-09 00:00:00Z]
  @vet "00000000-0000-0000-0000-0000000000a1"
  @nurse "00000000-0000-0000-0000-0000000000b1"
  @early "00000000-0000-0000-0000-0000000000e1"
  @nurse_early "00000000-0000-0000-0000-0000000000e2"
  @a1 "00000000-0000-0000-0000-0000000000c1"

  defp week(patterns),
    do:
      Map.new(
        1..7,
        &{&1, %{reserve_minutes: if(&1 <= 5, do: 30, else: 0), patterns: patterns.(&1)}}
      )

  defp facts(overrides \\ %{}) do
    Map.merge(
      %{
        week_start: ~D[2026-11-09],
        effective_at: @monday,
        clinicians: [
          %{id: @vet, role: :veterinarian, version: 0},
          %{id: @nurse, role: :nurse, version: 0}
        ],
        templates: [
          %{
            id: @early,
            name: "early",
            role: :veterinarian,
            from_minute: 480,
            to_minute: 960,
            days: [1, 2, 3, 4, 5],
            version: 0
          },
          %{
            id: @nurse_early,
            name: "early",
            role: :nurse,
            from_minute: 480,
            to_minute: 960,
            days: [1, 2, 3, 4, 5],
            version: 0
          }
        ],
        availabilities: [],
        appointments: [appointment(@a1, ~U[2026-11-09 10:07:00Z], 20)],
        shifts: [],
        assignments: [],
        policy: %{week: week(fn day -> if day <= 5, do: ["early"], else: [] end)}
      },
      overrides
    )
  end

  defp appointment(id, starts_at, minutes) do
    %{
      id: id,
      starts_at: starts_at,
      planned_ends_at: DateTime.add(starts_at, minutes * 60, :second),
      required_role: :veterinarian,
      booked_clinician_id: @vet,
      urgency: :urgent
    }
  end

  test "an appointment occupies floor(start)..ceil(end) slots: rounding never frees a used slot" do
    {:ok, %{"data" => data}} = Lowering.lower(facts())

    # 10:07 is inside slot 40 (10:00); 10:27 is inside slot 41 (10:15..10:30), so the end is 42.
    assert hd(data["a_from"]) == 40
    assert hd(data["a_to"]) == 42
    assert hd(data["a_weight"]) == 3
    assert hd(data["a_booked"]) == 1
    assert hd(data["a_role"]) == 1
  end

  test "a template runs on a day only if the template AND the policy allow it" do
    {:ok, %{"data" => data}} =
      Lowering.lower(
        facts(%{policy: %{week: week(fn day -> if day in [1, 2], do: ["early"], else: [] end)}})
      )

    first_template_days = Enum.slice(data["t_day_ok"], 0, 7)
    assert first_template_days == [true, true, false, false, false, false, false]
  end

  test "the grid: 96 slots a day, slot offsets from the template's minutes, role codes" do
    {:ok, %{"data" => data}} = Lowering.lower(facts())

    assert data["spd"] == 96
    assert Enum.take(data["t_from"], 2) == [32, 32]
    assert Enum.take(data["t_to"], 2) == [64, 64]
    assert Enum.take(data["t_role"], 2) == [1, 3]
    assert Enum.take(data["clin_role"], 2) == [1, 3]
    assert data["reserve_slots"] == [2, 2, 2, 2, 2, 0, 0]
  end

  test "every array that can be empty carries exactly one trailing pad element" do
    {:ok, %{"data" => data}} = Lowering.lower(facts(%{appointments: [], clinicians: []}))

    assert data["n_appt"] == 0
    assert data["a_from"] == [0]
    assert data["n_clin"] == 0
    assert data["clin_role"] == [0]
    assert data["n_unavail"] == 0
    assert data["u_clin"] == [0]
    assert data["prev_pat"] == [-1]
  end

  test "removed availability becomes slot intervals; available rows are not constraints" do
    availabilities = [
      %{
        id: "u1",
        clinician_id: @vet,
        starts_at: ~U[2026-11-09 12:00:00Z],
        ends_at: ~U[2026-11-09 13:10:00Z],
        available: false,
        version: 0
      },
      %{
        id: "u2",
        clinician_id: @vet,
        starts_at: ~U[2026-11-09 14:00:00Z],
        ends_at: ~U[2026-11-09 15:00:00Z],
        available: true,
        version: 0
      }
    ]

    {:ok, %{"data" => data}} = Lowering.lower(facts(%{availabilities: availabilities}))

    assert data["n_unavail"] == 1
    assert hd(data["u_clin"]) == 1
    assert hd(data["u_from"]) == 48
    # 13:10 rounds up to slot 53 (13:15): a removed minute is never given back.
    assert hd(data["u_to"]) == 53
  end

  test "no applied plan is -1 everywhere; an applied plan is the template index, 0 where nothing was applied" do
    {:ok, %{"data" => fresh}} = Lowering.lower(facts())
    assert Enum.take(fresh["prev_pat"], 14) == List.duplicate(-1, 14)

    shift = %{
      id: "s1",
      clinician_id: @vet,
      role: :veterinarian,
      starts_at: ~U[2026-11-10 08:00:00Z],
      ends_at: ~U[2026-11-10 16:00:00Z],
      shift_template_id: @early,
      version: 0
    }

    {:ok, %{"data" => replan}} =
      Lowering.lower(
        facts(%{
          shifts: [shift],
          assignments: [
            %{id: "x", appointment_id: @a1, clinician_id: @vet, role: :veterinarian, version: 0}
          ]
        })
      )

    # Clinician 1, Tuesday (day 2) is template 1; every other (clinician, day) is 0.
    assert Enum.take(replan["prev_pat"], 7) == [0, 1, 0, 0, 0, 0, 0]
    assert Enum.slice(replan["prev_pat"], 7, 7) == List.duplicate(0, 7)
    assert hd(replan["a_prev"]) == 1
  end

  test "a shift is matched to its template by offsets when it names none" do
    shift = %{
      id: "s1",
      clinician_id: @vet,
      role: :veterinarian,
      starts_at: ~U[2026-11-10 08:00:00Z],
      ends_at: ~U[2026-11-10 16:00:00Z],
      shift_template_id: nil,
      version: 0
    }

    {:ok, %{"data" => data}} = Lowering.lower(facts(%{shifts: [shift]}))
    assert Enum.take(data["prev_pat"], 7) == [0, 1, 0, 0, 0, 0, 0]
  end

  test "a template that is not slot-aligned is refused, not rounded" do
    bad = [
      %{
        id: @early,
        name: "early",
        role: :veterinarian,
        from_minute: 485,
        to_minute: 960,
        days: [1],
        version: 0
      }
    ]

    assert {:error, :template_not_slot_aligned} = Lowering.lower(facts(%{templates: bad}))
  end

  test "decode reads the model's answer back to instants, roles and ids" do
    {:ok, lowered} = Lowering.lower(facts())
    payload = Map.put(lowered, "problem", %{"week_start" => "2026-11-09"})

    # pat: row 0 (nobody), then clinician 1 (vet) works template 1 on Monday; clinician 2 never works.
    pat = List.duplicate(0, 7) ++ [1, 0, 0, 0, 0, 0, 0] ++ List.duplicate(0, 7)
    assert {:ok, decoded} = Lowering.decode(payload, %{"pat" => pat, "asg" => [1]})

    assert decoded["shifts"] == [
             %{
               "clinician_id" => @vet,
               "role" => "veterinarian",
               "starts_at" => "2026-11-09T08:00:00Z",
               "ends_at" => "2026-11-09T16:00:00Z",
               "shift_template_id" => @early
             }
           ]

    assert decoded["assignments"] == [
             %{"appointment_id" => @a1, "clinician_id" => @vet, "role" => "veterinarian"}
           ]

    assert decoded["uncovered"] == []

    assert {:ok, %{"uncovered" => [@a1], "assignments" => []}} =
             Lowering.decode(payload, %{"pat" => pat, "asg" => [0]})
  end

  test "an answer of the wrong shape is unreadable, never partially read" do
    {:ok, lowered} = Lowering.lower(facts())
    payload = Map.put(lowered, "problem", %{"week_start" => "2026-11-09"})

    assert {:error, :answer_unreadable} = Lowering.decode(payload, %{"pat" => [0], "asg" => [1]})
    assert {:error, :answer_unreadable} = Lowering.decode(payload, %{"asg" => [1]})
  end
end
