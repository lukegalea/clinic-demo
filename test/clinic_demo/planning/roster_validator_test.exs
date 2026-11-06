defmodule ClinicDemo.Planning.RosterValidatorTest do
  @moduledoc """
  The independent roster validator, rule by rule, over a hand-written domain-level
  problem. Nothing here touches the model, the lowering or the database: the
  validator reads instants, minutes, role names and ids, so these tests do too.

  One week, Monday 2026-11-09 (ISO day 1) and Tuesday (day 2); one vet, one nurse;
  an "early" pattern 08:00-16:00 on weekdays and the policy's 30-minute reserve.
  """

  use ExUnit.Case, async: true

  alias ClinicDemo.Planning.RosterValidator

  @vet "00000000-0000-0000-0000-0000000000a1"
  @vet2 "00000000-0000-0000-0000-0000000000a2"
  @nurse "00000000-0000-0000-0000-0000000000b1"
  @a1 "00000000-0000-0000-0000-0000000000c1"
  @a2 "00000000-0000-0000-0000-0000000000c2"
  @a3 "00000000-0000-0000-0000-0000000000c3"

  defp problem(overrides \\ %{}) do
    Map.merge(
      %{
        "week_start" => "2026-11-09",
        "clinicians" => [
          %{"id" => @vet, "role" => "veterinarian"},
          %{"id" => @vet2, "role" => "veterinarian"},
          %{"id" => @nurse, "role" => "nurse"}
        ],
        "templates" => [
          %{
            "id" => "t1",
            "name" => "early",
            "role" => "veterinarian",
            "from_minute" => 480,
            "to_minute" => 960,
            "days" => [1, 2, 3, 4, 5]
          },
          %{
            "id" => "t2",
            "name" => "early",
            "role" => "nurse",
            "from_minute" => 480,
            "to_minute" => 960,
            "days" => [1, 2, 3, 4, 5]
          }
        ],
        "unavailable" => [],
        "appointments" => [
          appointment(@a1, "2026-11-09T10:00:00Z", "2026-11-09T10:30:00Z", "veterinarian"),
          appointment(@a2, "2026-11-09T11:00:00Z", "2026-11-09T11:30:00Z", "veterinarian")
        ],
        "reserve_minutes" => Map.new(1..7, &{Integer.to_string(&1), 30}),
        "allowed_patterns" =>
          Map.new(1..5, &{Integer.to_string(&1), ["early"]}) |> Map.merge(%{"6" => [], "7" => []})
      },
      overrides
    )
  end

  defp appointment(id, from, to, role),
    do: %{
      "id" => id,
      "starts_at" => from,
      "ends_at" => to,
      "required_role" => role,
      "booked_clinician_id" => nil
    }

  defp shift(clinician, role, from, to),
    do: %{
      "clinician_id" => clinician,
      "role" => role,
      "starts_at" => from,
      "ends_at" => to,
      "shift_template_id" => nil
    }

  defp cover(appointment, clinician, role \\ "veterinarian"),
    do: %{"appointment_id" => appointment, "clinician_id" => clinician, "role" => role}

  defp valid_plan do
    %{
      "shifts" => [shift(@vet, "veterinarian", "2026-11-09T08:00:00Z", "2026-11-09T16:00:00Z")],
      "assignments" => [cover(@a1, @vet), cover(@a2, @vet)],
      "uncovered" => []
    }
  end

  defp codes({:error, violations}), do: violations |> Enum.map(& &1.code) |> Enum.sort()

  test "a roster that follows every rule is accepted" do
    assert RosterValidator.validate(problem(), valid_plan()) == :ok
  end

  test "an uncovered appointment, declared as such, is accepted: exposure is not an error" do
    plan = %{valid_plan() | "assignments" => [cover(@a1, @vet)], "uncovered" => [@a2]}
    assert RosterValidator.validate(problem(), plan) == :ok
  end

  describe "accounting" do
    test "an appointment neither covered nor declared uncovered is refused" do
      plan = %{valid_plan() | "assignments" => [cover(@a1, @vet)]}
      assert codes(RosterValidator.validate(problem(), plan)) == [:appointment_unaccounted]
    end

    test "an appointment covered twice is refused" do
      plan = %{
        valid_plan()
        | "assignments" => [cover(@a1, @vet), cover(@a1, @vet), cover(@a2, @vet)]
      }

      assert :appointment_double_booked in codes(RosterValidator.validate(problem(), plan))
    end

    test "an appointment both covered and declared uncovered is refused" do
      plan = %{valid_plan() | "uncovered" => [@a1]}
      assert :appointment_double_booked in codes(RosterValidator.validate(problem(), plan))
    end

    test "an appointment the problem does not know is refused" do
      plan = %{valid_plan() | "uncovered" => ["00000000-0000-0000-0000-0000000000ff"]}
      assert :unknown_appointment in codes(RosterValidator.validate(problem(), plan))
    end
  end

  describe "role" do
    test "an appointment attended by the wrong role is refused" do
      plan = %{
        valid_plan()
        | "shifts" => [shift(@nurse, "nurse", "2026-11-09T08:00:00Z", "2026-11-09T16:00:00Z")],
          "assignments" => [cover(@a1, @nurse, "nurse"), cover(@a2, @nurse, "nurse")]
      }

      assert :role_mismatch in codes(RosterValidator.validate(problem(), plan))
    end

    test "a shift in a role other than the clinician's is refused" do
      plan = %{
        valid_plan()
        | "shifts" => [shift(@vet, "nurse", "2026-11-09T08:00:00Z", "2026-11-09T16:00:00Z")]
      }

      assert :shift_role_mismatch in codes(RosterValidator.validate(problem(), plan))
    end

    test "a shift for a clinician not on the roster is refused" do
      plan = %{
        valid_plan()
        | "shifts" => [
            shift("nobody", "veterinarian", "2026-11-09T08:00:00Z", "2026-11-09T16:00:00Z")
          ]
      }

      assert :unknown_clinician in codes(RosterValidator.validate(problem(), plan))
    end
  end

  describe "window" do
    test "an appointment outside the clinician's shift is refused" do
      plan = %{
        valid_plan()
        | "shifts" => [
            shift(@vet, "veterinarian", "2026-11-09T08:00:00Z", "2026-11-09T10:15:00Z")
          ]
      }

      found = codes(RosterValidator.validate(problem(), plan))
      assert :outside_shift_window in found
      assert :shift_pattern_not_allowed in found
    end

    test "an appointment on a day the clinician does not work is refused" do
      plan = %{
        valid_plan()
        | "shifts" => [
            shift(@vet, "veterinarian", "2026-11-10T08:00:00Z", "2026-11-10T16:00:00Z")
          ]
      }

      assert :outside_shift_window in codes(RosterValidator.validate(problem(), plan))
    end

    test "an appointment that starts exactly when the shift does fits (half-open)" do
      problem =
        problem(%{
          "appointments" => [
            appointment(@a1, "2026-11-09T08:00:00Z", "2026-11-09T08:30:00Z", "veterinarian")
          ]
        })

      plan = %{valid_plan() | "assignments" => [cover(@a1, @vet)], "uncovered" => []}
      assert RosterValidator.validate(problem, plan) == :ok
    end

    test "an appointment that ends exactly when the shift does fits (half-open)" do
      problem =
        problem(%{
          "appointments" => [
            appointment(@a1, "2026-11-09T15:00:00Z", "2026-11-09T15:30:00Z", "veterinarian")
          ]
        })

      plan = %{valid_plan() | "assignments" => [cover(@a1, @vet)]}
      assert RosterValidator.validate(problem, plan) == :ok
    end

    test "a shift that is not an allowed pattern is refused" do
      plan = %{
        valid_plan()
        | "shifts" => [
            shift(@vet, "veterinarian", "2026-11-09T07:00:00Z", "2026-11-09T16:00:00Z")
          ]
      }

      assert :shift_pattern_not_allowed in codes(RosterValidator.validate(problem(), plan))
    end

    test "a pattern the day's policy does not allow is refused even though the template exists" do
      problem = problem(%{"allowed_patterns" => Map.new(1..7, &{Integer.to_string(&1), []})})
      assert :shift_pattern_not_allowed in codes(RosterValidator.validate(problem, valid_plan()))
    end
  end

  describe "overlap" do
    test "two overlapping appointments for one clinician are refused" do
      problem =
        problem(%{
          "appointments" => [
            appointment(@a1, "2026-11-09T10:00:00Z", "2026-11-09T10:30:00Z", "veterinarian"),
            appointment(@a2, "2026-11-09T10:15:00Z", "2026-11-09T10:45:00Z", "veterinarian")
          ]
        })

      assert :overlap in codes(RosterValidator.validate(problem, valid_plan()))
    end

    test "back-to-back appointments touch but do not overlap (half-open)" do
      problem =
        problem(%{
          "appointments" => [
            appointment(@a1, "2026-11-09T10:00:00Z", "2026-11-09T10:30:00Z", "veterinarian"),
            appointment(@a2, "2026-11-09T10:30:00Z", "2026-11-09T11:00:00Z", "veterinarian")
          ]
        })

      assert RosterValidator.validate(problem, valid_plan()) == :ok
    end

    test "overlapping appointments with two different clinicians are fine" do
      problem =
        problem(%{
          "appointments" => [
            appointment(@a1, "2026-11-09T10:00:00Z", "2026-11-09T10:30:00Z", "veterinarian"),
            appointment(@a2, "2026-11-09T10:15:00Z", "2026-11-09T10:45:00Z", "veterinarian")
          ]
        })

      plan = %{
        valid_plan()
        | "shifts" => [
            shift(@vet, "veterinarian", "2026-11-09T08:00:00Z", "2026-11-09T16:00:00Z"),
            shift(@vet2, "veterinarian", "2026-11-09T08:00:00Z", "2026-11-09T16:00:00Z")
          ],
          "assignments" => [cover(@a1, @vet), cover(@a2, @vet2)]
      }

      assert RosterValidator.validate(problem, plan) == :ok
    end

    test "two overlapping shifts for one clinician are refused" do
      plan = %{
        valid_plan()
        | "shifts" => [
            shift(@vet, "veterinarian", "2026-11-09T08:00:00Z", "2026-11-09T16:00:00Z"),
            shift(@vet, "veterinarian", "2026-11-09T08:00:00Z", "2026-11-09T16:00:00Z")
          ]
      }

      assert :shift_overlap in codes(RosterValidator.validate(problem(), plan))
    end
  end

  describe "availability" do
    test "a shift through removed availability is refused" do
      problem =
        problem(%{
          "unavailable" => [
            %{
              "clinician_id" => @vet,
              "starts_at" => "2026-11-09T12:00:00Z",
              "ends_at" => "2026-11-09T13:00:00Z"
            }
          ]
        })

      assert :shift_in_unavailable_window in codes(
               RosterValidator.validate(problem, valid_plan())
             )
    end

    test "availability removed for another clinician does not matter" do
      problem =
        problem(%{
          "unavailable" => [
            %{
              "clinician_id" => @vet2,
              "starts_at" => "2026-11-09T12:00:00Z",
              "ends_at" => "2026-11-09T13:00:00Z"
            }
          ]
        })

      assert RosterValidator.validate(problem, valid_plan()) == :ok
    end

    test "availability that ends exactly when the shift starts does not conflict (half-open)" do
      problem =
        problem(%{
          "unavailable" => [
            %{
              "clinician_id" => @vet,
              "starts_at" => "2026-11-09T06:00:00Z",
              "ends_at" => "2026-11-09T08:00:00Z"
            }
          ]
        })

      assert RosterValidator.validate(problem, valid_plan()) == :ok
    end
  end

  describe "reserve" do
    test "a shift filled past its reserve is refused" do
      # 08:00-16:00 is 480 minutes; 30 reserved leaves 450. Three 150-minute visits is 450 (ok),
      # a fourth minute over is not.
      busy = [
        appointment(@a1, "2026-11-09T08:00:00Z", "2026-11-09T10:30:00Z", "veterinarian"),
        appointment(@a2, "2026-11-09T10:30:00Z", "2026-11-09T13:00:00Z", "veterinarian"),
        appointment(@a3, "2026-11-09T13:00:00Z", "2026-11-09T15:31:00Z", "veterinarian")
      ]

      plan = %{
        valid_plan()
        | "assignments" => [cover(@a1, @vet), cover(@a2, @vet), cover(@a3, @vet)]
      }

      assert :reserve_violated in codes(
               RosterValidator.validate(problem(%{"appointments" => busy}), plan)
             )

      exactly =
        List.replace_at(
          busy,
          2,
          appointment(@a3, "2026-11-09T13:00:00Z", "2026-11-09T15:30:00Z", "veterinarian")
        )

      assert RosterValidator.validate(problem(%{"appointments" => exactly}), plan) == :ok
    end
  end

  test "violations carry structural subjects and details only" do
    plan = %{valid_plan() | "assignments" => []}

    assert {:error, [%{code: :appointment_unaccounted, subject: subject, detail: %{}} | _]} =
             RosterValidator.validate(problem(), plan)

    assert subject in [@a1, @a2]
  end
end
