defmodule ClinicDemo.Planning.RosterPlan do
  @moduledoc """
  The weekly roster's side of the planning loop: the `ClinicDemo.Planning.Model`
  callbacks of `ClinicDemo.Planning.Models.WeeklyRoster`.

    * `build/4` reads the week (`ClinicDemo.Planning.Reader`, `as_of` the cutoff),
      asks the pinned `staffing.policy` decision, and lowers everything
      (`ClinicDemo.Planning.Lowering`) alongside the domain-level problem the
      independent validator reads;
    * `decode/2`, `summarize/3`, `obligations/1` and `validate/2` read a model answer
      back to shifts and assignments, say how much of the applied plan it keeps, name
      the appointments left uncovered, and check it with `RosterValidator`;
    * `current_inputs/1` and `apply_plan/3` are `Candidate.apply`: the inputs as they
      are now, and the `Shift`/`Assignment` writes, diffed against what is applied.
  """

  alias AshOpenLineage.Snapshot.Definition
  alias ClinicDemo.Planning.Checks.AppliedByCandidate
  alias ClinicDemo.Planning.{Lowering, Reader, RosterValidator, StaffingPolicy}
  alias ClinicDemo.Scheduling

  @decision_key "staffing.policy"

  # ── scope / build ──────────────────────────────────────────────────────────

  @doc "What a roster plan is about: the week."
  @spec scope(keyword()) :: map()
  def scope(opts), do: %{"week_start" => Date.to_iso8601(Keyword.fetch!(opts, :week_start))}

  @doc """
  Reads and lowers the week named by `:week_start` (a Monday, required) as of
  `cutoff`. The lowered body is `nil` when an input is unresolved: nothing is solved
  for a week that cannot be planned as it stands.
  """
  @spec build(struct(), keyword(), DateTime.t(), [Definition.t()]) ::
          {:ok, ClinicDemo.Planning.Model.built()} | {:error, term()}
  def build(_run, opts, cutoff, definitions) do
    week_start = Keyword.fetch!(opts, :week_start)

    unless Date.day_of_week(week_start) == 1,
      do: raise(ArgumentError, "week_start must be a Monday, got #{week_start}")

    with {:ok, decision} <- pinned_decision(definitions),
         facts = Reader.read(week_start, cutoff),
         {:ok, policy} <- policy(decision, facts) do
      annotated = annotate(facts, policy)
      inputs = Reader.inputs(annotated)

      built = %{
        effective_at: annotated.effective_at,
        inputs: inputs,
        reasons:
          for(i <- inputs, i.status == :invalid, into: %{}, do: {i.key, "crosses_midnight"}),
        stats: %{
          "week_start" => Date.to_iso8601(week_start),
          "appointments" => length(annotated.appointments)
        },
        body: nil
      }

      if Enum.all?(inputs, &(&1.status == :value)) do
        with {:ok, lowered} <- Lowering.lower(annotated) do
          {:ok, %{built | body: Map.put(lowered, "problem", validator_problem(annotated))}}
        end
      else
        {:ok, built}
      end
    end
  end

  defp pinned_decision(definitions) do
    case Enum.find(definitions, &(&1.kind == :dmn and &1.key == @decision_key)) do
      nil ->
        {:error, :decision_not_pinned}

      %Definition{version: version, content_hash: hash} ->
        StaffingPolicy.fetch_definition(@decision_key, String.to_integer(version), hash)
    end
  end

  defp policy(decision, facts) do
    names = Enum.map(facts.appointments, & &1.type_name)
    StaffingPolicy.evaluate(decision, names)
  end

  # The decision's answers, attached to the facts the model and the validator read.
  defp annotate(facts, policy) do
    appointments =
      Enum.map(facts.appointments, fn a ->
        answer = Map.fetch!(policy.appointment, a.type_name || "")
        minutes = max(a.booked_minutes, answer.duration_minutes)

        Map.merge(a, %{
          required_role: answer.role,
          planned_minutes: minutes,
          planned_ends_at: DateTime.add(a.starts_at, minutes * 60, :second)
        })
      end)

    facts |> Map.put(:appointments, appointments) |> Map.put(:policy, policy)
  end

  # The domain-level problem the independent validator reads. Instants are
  # ISO-8601, durations are minutes, roles are names, days are "1".."7": nothing
  # here is a slot index or a model code.
  defp validator_problem(facts) do
    %{
      "week_start" => Date.to_iso8601(facts.week_start),
      "clinicians" =>
        for(c <- facts.clinicians, do: %{"id" => c.id, "role" => Atom.to_string(c.role)}),
      "templates" =>
        for t <- facts.templates do
          %{
            "id" => t.id,
            "name" => t.name,
            "role" => Atom.to_string(t.role),
            "from_minute" => t.from_minute,
            "to_minute" => t.to_minute,
            "days" => t.days
          }
        end,
      "unavailable" =>
        for a <- facts.availabilities, not a.available do
          %{
            "clinician_id" => a.clinician_id,
            "starts_at" => DateTime.to_iso8601(a.starts_at),
            "ends_at" => DateTime.to_iso8601(a.ends_at)
          }
        end,
      "appointments" =>
        for a <- facts.appointments do
          %{
            "id" => a.id,
            "starts_at" => DateTime.to_iso8601(a.starts_at),
            "ends_at" => DateTime.to_iso8601(a.planned_ends_at),
            "required_role" => Atom.to_string(a.required_role),
            "booked_clinician_id" => a.booked_clinician_id
          }
        end,
      "reserve_minutes" =>
        Map.new(facts.policy.week, fn {day, w} -> {Integer.to_string(day), w.reserve_minutes} end),
      "allowed_patterns" =>
        Map.new(facts.policy.week, fn {day, w} -> {Integer.to_string(day), w.patterns} end),
      "previous" => %{
        "shifts" =>
          for s <- facts.shifts do
            %{
              "clinician_id" => s.clinician_id,
              "starts_at" => DateTime.to_iso8601(s.starts_at),
              "ends_at" => DateTime.to_iso8601(s.ends_at)
            }
          end,
        "assignments" =>
          for a <- facts.assignments do
            %{"appointment_id" => a.appointment_id, "clinician_id" => a.clinician_id}
          end
      }
    }
  end

  # ── reading an answer ──────────────────────────────────────────────────────

  @doc "A model answer read back to shifts, covered and uncovered appointments."
  @spec decode(map(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate decode(payload, answer), to: Lowering

  @doc """
  The decoded assignments plus what a person reading the candidate wants to know
  without opening the model: how much of the applied plan it keeps.
  """
  @spec summarize(map(), map(), map()) :: map()
  def summarize(assignments, payload, candidate) do
    previous = get_in(payload, ["problem", "previous", "assignments"]) || []

    kept =
      Enum.count(previous, fn p ->
        Enum.any?(
          assignments["assignments"],
          &(&1["appointment_id"] == p["appointment_id"] and
              &1["clinician_id"] == p["clinician_id"])
        )
      end)

    assignments
    |> Map.put("preserved_assignments", kept)
    |> Map.put("previous_assignments", length(previous))
    |> Map.put("objective", candidate[:objective] && Decimal.to_string(candidate[:objective]))
  end

  @doc "One unresolved obligation per uncovered appointment: an id and a reason code."
  @spec obligations(map()) :: [map()]
  def obligations(assignments) do
    for id <- assignments["uncovered"] do
      %{"id" => id, "kind" => "appointment", "reason" => "uncovered"}
    end
  end

  @doc "The independent check: `RosterValidator`."
  @spec validate(map(), map()) :: :ok | {:error, [AshPlanning.Violation.t()]}
  defdelegate validate(problem, assignments), to: RosterValidator

  # ── apply ──────────────────────────────────────────────────────────────────

  @doc "The week's inputs as they are now (the freshness recheck's other side)."
  @spec current_inputs(map()) :: {:ok, [AshOpenLineage.Snapshot.Input.t()]} | {:error, term()}
  def current_inputs(payload) do
    with {:ok, week_start} <- Date.from_iso8601(payload["problem"]["week_start"]) do
      {:ok, week_start |> Reader.read(DateTime.utc_now()) |> Reader.inputs()}
    else
      _ -> {:error, :problem_unreadable}
    end
  end

  @doc """
  Writes the candidate's whole-week plan as the approving person: shifts and
  assignments the week already has and the plan keeps are left alone (and counted as
  preserved); ones the plan drops are cancelled; new ones are placed. Cancels first,
  then placements, inside the apply's transaction and under the apply marker
  (`Checks.AppliedByCandidate`). The first refusal stops the rest and is returned;
  the caller rolls everything back. Returns `{:error, {:refused, error}}` for a
  refused write and a bare atom for a candidate or problem that cannot be read.
  """
  @spec apply_plan(struct(), map(), map()) :: {:ok, map()} | {:error, term()}
  def apply_plan(candidate, payload, actor) do
    with {:ok, plan} <- plan(candidate),
         {:ok, week_start} <- Date.from_iso8601(payload["problem"]["week_start"]) do
      facts = Reader.read(week_start, DateTime.utc_now())
      transact(candidate, plan, facts, actor)
    end
  end

  defp plan(candidate) do
    with binary when is_binary(binary) <- candidate.assignments,
         {:ok, %{"shifts" => shifts, "assignments" => assignments}} <- Jason.decode(binary) do
      {:ok, %{shifts: Enum.map(shifts, &parse_shift/1), assignments: assignments}}
    else
      _ -> {:error, :assignments_unreadable}
    end
  end

  defp parse_shift(shift) do
    {:ok, starts_at, _} = DateTime.from_iso8601(shift["starts_at"])
    {:ok, ends_at, _} = DateTime.from_iso8601(shift["ends_at"])
    %{shift | "starts_at" => starts_at, "ends_at" => ends_at}
  end

  defp transact(candidate, plan, facts, actor) do
    opts = [actor: actor]

    shift_key = &{&1.clinician_id, &1.starts_at, &1.ends_at}
    planned_shift_key = &{&1["clinician_id"], &1["starts_at"], &1["ends_at"]}
    assignment_key = &{&1.appointment_id, &1.clinician_id}
    planned_assignment_key = &{&1["appointment_id"], &1["clinician_id"]}

    {keep_shifts, drop_shifts} = split(facts.shifts, shift_key, plan.shifts, planned_shift_key)

    {keep_assignments, drop_assignments} =
      split(facts.assignments, assignment_key, plan.assignments, planned_assignment_key)

    kept_shift_keys = MapSet.new(keep_shifts, shift_key)
    kept_assignment_keys = MapSet.new(keep_assignments, assignment_key)

    place_shifts =
      Enum.reject(plan.shifts, &MapSet.member?(kept_shift_keys, planned_shift_key.(&1)))

    place_assignments =
      Enum.reject(
        plan.assignments,
        &MapSet.member?(kept_assignment_keys, planned_assignment_key.(&1))
      )

    steps =
      Enum.map(drop_assignments, &{:cancel_assignment, &1}) ++
        Enum.map(drop_shifts, &{:cancel_shift, &1}) ++
        Enum.map(place_shifts, &{:place_shift, &1}) ++
        Enum.map(place_assignments, &{:place_assignment, &1})

    # We are already inside the apply action's transaction: every write below
    # joins it, and returning the error from this hook rolls all of them back
    # together.
    result =
      AppliedByCandidate.with_marker(
        candidate.id,
        MapSet.new(Enum.map(drop_assignments ++ drop_shifts, & &1.id)),
        fn ->
          Enum.reduce_while(steps, :ok, fn step, :ok ->
            case run_step(step, candidate.id, opts) do
              :ok -> {:cont, :ok}
              {:error, error} -> {:halt, {:error, error}}
            end
          end)
        end
      )

    case result do
      :ok ->
        {:ok,
         %{
           placed_shifts: length(place_shifts),
           placed_assignments: length(place_assignments),
           cancelled_shifts: length(drop_shifts),
           cancelled_assignments: length(drop_assignments),
           preserved_shifts: length(keep_shifts),
           preserved_assignments: length(keep_assignments)
         }}

      {:error, error} ->
        {:error, {:refused, error}}
    end
  end

  # {applied rows the plan keeps, applied rows the plan drops}
  defp split(applied, applied_key, planned, planned_key) do
    planned_keys = MapSet.new(planned, planned_key)
    Enum.split_with(applied, &MapSet.member?(planned_keys, applied_key.(&1)))
  end

  defp run_step({:cancel_assignment, row}, _candidate_id, opts),
    do: ok(Scheduling.cancel_assignment(row.id, %{}, opts))

  defp run_step({:cancel_shift, row}, _candidate_id, opts),
    do: ok(Scheduling.cancel_shift(row.id, %{}, opts))

  defp run_step({:place_shift, shift}, candidate_id, opts) do
    ok(
      Scheduling.place_shift(
        %{
          role: shift["role"],
          starts_at: shift["starts_at"],
          ends_at: shift["ends_at"],
          candidate_id: candidate_id,
          clinician_id: shift["clinician_id"],
          shift_template_id: shift["shift_template_id"]
        },
        opts
      )
    )
  end

  defp run_step({:place_assignment, assignment}, candidate_id, opts) do
    ok(
      Scheduling.place_assignment(
        %{
          appointment_id: assignment["appointment_id"],
          role: assignment["role"],
          candidate_id: candidate_id,
          clinician_id: assignment["clinician_id"]
        },
        opts
      )
    )
  end

  defp ok({:ok, _record}), do: :ok
  defp ok({:error, error}), do: {:error, error}
end
