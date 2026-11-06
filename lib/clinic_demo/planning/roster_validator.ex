defmodule ClinicDemo.Planning.RosterValidator do
  @moduledoc """
  The independent Elixir validator for `weekly_roster`: it re-checks a decoded
  candidate against the **domain-level problem** and shares nothing with the
  model, the checker or `ClinicDemo.Planning.Lowering`.

  It reads instants, minutes, role names and ids. It has no slot grid, no role
  codes and no model indices, so a bug in the lowering (an off-by-one in a slot,
  a swapped role code) cannot also be a bug here. Overlap is the generic
  `AshPlanning.Validators.Intervals` over plain unix seconds; every other rule is
  written out below in the vocabulary of the clinic.

      validate(problem, assignments) :: :ok | {:error, [AshPlanning.Violation.t()]}

  `problem` is the payload's `"problem"` map (string keys); `assignments` is
  `Lowering.decode/2`'s output: `"shifts"`, `"assignments"` and `"uncovered"`.

  ## Rules (half-open intervals throughout)

    * a shift is for a known clinician, in their role, and is one of the allowed
      patterns for its weekday (a template of that role with the same minutes,
      allowed on the day, named by the day's `allowed_patterns`);
    * a clinician's shifts do not overlap each other nor removed availability;
    * every appointment is either covered once or declared uncovered, never both
      and never neither;
    * a covered appointment is attended by a clinician whose role is the required
      role, entirely inside one of that clinician's shifts;
    * one clinician never attends two overlapping appointments;
    * every worked clinician-day keeps its reserve minutes unassigned.

  Violation codes: `:unknown_clinician`, `:shift_role_mismatch`,
  `:shift_pattern_not_allowed`, `:shift_overlap`, `:shift_in_unavailable_window`,
  `:unknown_appointment`, `:appointment_unaccounted`, `:appointment_double_booked`,
  `:role_mismatch`, `:outside_shift_window`, `:overlap`, `:reserve_violated`.
  Subjects are ids; details are structural.
  """

  @behaviour AshPlanning.Validator

  alias AshPlanning.Validators.{Intervals, Support}
  alias AshPlanning.Violation

  @impl true
  def validate(problem, assignments) do
    clinicians = Map.new(list(problem, "clinicians"), &{&1["id"], &1})
    appointments = Map.new(list(problem, "appointments"), &{&1["id"], &1})
    shifts = list(assignments, "shifts")
    covered = list(assignments, "assignments")
    uncovered = list(assignments, "uncovered")

    violations =
      shift_violations(problem, clinicians, shifts) ++
        accounting_violations(appointments, covered, uncovered) ++
        coverage_violations(problem, clinicians, appointments, shifts, covered)

    Support.result(violations)
  end

  # ── shifts ─────────────────────────────────────────────────────────────────

  defp shift_violations(problem, clinicians, shifts) do
    per_shift =
      Enum.flat_map(shifts, fn shift ->
        id = shift_id(shift)

        case clinicians[shift["clinician_id"]] do
          nil ->
            [Violation.new(:unknown_clinician, id, %{})]

          clinician ->
            role_violations(id, shift, clinician) ++ pattern_violations(id, shift, problem)
        end
      end)

    items =
      Enum.map(shifts, &interval(&1, shift_id(&1), "starts_at", "ends_at", &1["clinician_id"]))

    unavailable =
      for u <- list(problem, "unavailable") do
        interval(
          u,
          "unavailable:#{u["clinician_id"]}:#{u["starts_at"]}",
          "starts_at",
          "ends_at",
          u["clinician_id"]
        )
      end

    overlap =
      case Intervals.validate(%{pinned: unavailable}, items) do
        :ok -> []
        {:error, found} -> Enum.map(found, &rename_shift/1)
      end

    per_shift ++ overlap
  end

  defp role_violations(id, shift, clinician) do
    if shift["role"] == clinician["role"],
      do: [],
      else: [
        Violation.new(:shift_role_mismatch, id, %{
          shift: shift["role"],
          clinician: clinician["role"]
        })
      ]
  end

  # One of the problem's templates, of this role, with these minutes, allowed on
  # this weekday by the template and by the decision's allowed patterns.
  defp pattern_violations(id, shift, problem) do
    with {:ok, starts_at} <- instant(shift["starts_at"]),
         {:ok, ends_at} <- instant(shift["ends_at"]) do
      day = Date.day_of_week(DateTime.to_date(starts_at))
      from = starts_at.hour * 60 + starts_at.minute
      to = from + div(DateTime.diff(ends_at, starts_at, :second), 60)
      allowed = get_in(problem, ["allowed_patterns", Integer.to_string(day)]) || []

      allowed? =
        Enum.any?(list(problem, "templates"), fn t ->
          t["role"] == shift["role"] and t["from_minute"] == from and t["to_minute"] == to and
            day in t["days"] and t["name"] in allowed
        end)

      if allowed?,
        do: [],
        else: [
          Violation.new(:shift_pattern_not_allowed, id, %{
            day: day,
            from_minute: from,
            to_minute: to
          })
        ]
    else
      _ -> [Violation.new(:shift_pattern_not_allowed, id, %{reason: :unreadable_instant})]
    end
  end

  defp rename_shift(%{code: :overlap} = v), do: %{v | code: :shift_overlap}
  defp rename_shift(%{code: :overlaps_pinned} = v), do: %{v | code: :shift_in_unavailable_window}
  defp rename_shift(v), do: v

  # ── accounting: every appointment exactly once ─────────────────────────────

  defp accounting_violations(appointments, covered, uncovered) do
    covered_ids = Enum.map(covered, & &1["appointment_id"])
    unknown = for id <- covered_ids ++ uncovered, not Map.has_key?(appointments, id), do: id
    twice = covered_ids |> Enum.frequencies() |> Enum.filter(fn {_id, n} -> n > 1 end)
    declared_both = for id <- uncovered, id in covered_ids, do: id

    unaccounted =
      for {id, _a} <- appointments, id not in covered_ids and id not in uncovered, do: id

    Enum.map(Enum.uniq(unknown), &Violation.new(:unknown_appointment, &1, %{})) ++
      Enum.map(twice, fn {id, n} -> Violation.new(:appointment_double_booked, id, %{times: n}) end) ++
      Enum.map(
        Enum.uniq(declared_both),
        &Violation.new(:appointment_double_booked, &1, %{also: :uncovered})
      ) ++
      Enum.map(unaccounted, &Violation.new(:appointment_unaccounted, &1, %{}))
  end

  # ── coverage ───────────────────────────────────────────────────────────────

  defp coverage_violations(problem, clinicians, appointments, shifts, covered) do
    per_assignment =
      Enum.flat_map(covered, fn assignment ->
        appointment = appointments[assignment["appointment_id"]]
        clinician = clinicians[assignment["clinician_id"]]

        if is_nil(appointment) or is_nil(clinician) do
          []
        else
          id = assignment["appointment_id"]

          role_check(id, assignment, appointment, clinician) ++
            window_check(id, appointment, assignment, shifts)
        end
      end)

    items =
      for assignment <- covered,
          appointment = appointments[assignment["appointment_id"]],
          not is_nil(appointment) do
        interval(
          appointment,
          assignment["appointment_id"],
          "starts_at",
          "ends_at",
          assignment["clinician_id"]
        )
      end

    overlap =
      case Intervals.validate(%{}, items) do
        :ok -> []
        {:error, found} -> found
      end

    per_assignment ++ overlap ++ reserve_violations(problem, appointments, shifts, covered)
  end

  defp role_check(id, assignment, appointment, clinician) do
    if clinician["role"] == appointment["required_role"] and
         assignment["role"] == appointment["required_role"],
       do: [],
       else: [
         Violation.new(:role_mismatch, id, %{
           required: appointment["required_role"],
           clinician: clinician["role"]
         })
       ]
  end

  defp window_check(id, appointment, assignment, shifts) do
    {:ok, starts_at} = instant(appointment["starts_at"])
    {:ok, ends_at} = instant(appointment["ends_at"])

    inside? =
      Enum.any?(shifts, fn shift ->
        with true <- shift["clinician_id"] == assignment["clinician_id"],
             {:ok, shift_start} <- instant(shift["starts_at"]),
             {:ok, shift_end} <- instant(shift["ends_at"]) do
          DateTime.compare(shift_start, starts_at) != :gt and
            DateTime.compare(ends_at, shift_end) != :gt
        else
          _ -> false
        end
      end)

    if inside?, do: [], else: [Violation.new(:outside_shift_window, id, %{})]
  end

  # Per worked clinician-day: minutes assigned <= shift minutes - reserve.
  defp reserve_violations(problem, appointments, shifts, covered) do
    for shift <- shifts,
        {:ok, shift_start} <- [instant(shift["starts_at"])],
        {:ok, shift_end} <- [instant(shift["ends_at"])],
        day = Date.day_of_week(DateTime.to_date(shift_start)),
        reserve = get_in(problem, ["reserve_minutes", Integer.to_string(day)]) || 0,
        busy = busy_minutes(shift, shift_start, shift_end, appointments, covered),
        shift_minutes = div(DateTime.diff(shift_end, shift_start, :second), 60),
        busy > shift_minutes - reserve do
      Violation.new(:reserve_violated, shift_id(shift), %{
        busy_minutes: busy,
        shift_minutes: shift_minutes,
        reserve_minutes: reserve
      })
    end
  end

  defp busy_minutes(shift, shift_start, shift_end, appointments, covered) do
    for assignment <- covered,
        assignment["clinician_id"] == shift["clinician_id"],
        appointment = appointments[assignment["appointment_id"]],
        {:ok, starts_at} <- [instant(appointment["starts_at"])],
        {:ok, ends_at} <- [instant(appointment["ends_at"])],
        DateTime.compare(starts_at, shift_end) == :lt and
          DateTime.compare(ends_at, shift_start) == :gt,
        reduce: 0 do
      acc -> acc + div(DateTime.diff(ends_at, starts_at, :second), 60)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp list(map, key), do: Map.get(map, key) || []

  defp shift_id(shift), do: "shift:#{shift["clinician_id"]}:#{shift["starts_at"]}"

  # An `Intervals` item: unix seconds, grouped by resource.
  defp interval(row, id, start_key, end_key, resource) do
    {:ok, starts_at} = instant(row[start_key])
    {:ok, ends_at} = instant(row[end_key])

    %{
      id: id,
      start: DateTime.to_unix(starts_at),
      end: DateTime.to_unix(ends_at),
      resource: resource
    }
  end

  defp instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      error -> error
    end
  end

  defp instant(%DateTime{} = dt), do: {:ok, dt}
  defp instant(_other), do: :error
end
