defmodule ClinicDemo.Planning.RosterCheckerTest do
  @moduledoc """
  The MiniZinc solution checker and the independent validator, side by side, on
  deliberately corrupted rosters. Each case is built from a real prepared run's
  payload, so the data is exactly what the model is given.

  A corrupted roster must be rejected by BOTH: the checker (UNSAT when run against
  the candidate's variables, which the Solverl backend reports as `:infeasible`)
  and the validator (a violation with the right code). One agreeing and the other
  not would be the signal that the model's lowering and the validator disagree
  about what a roster means.

  Needs MiniZinc (`:solver`); skipped without it.
  """

  use ClinicDemo.DataCase, async: false

  import ClinicDemo.PlanningFixtures

  alias AshPlanning.{Backend, Problem}
  alias ClinicDemo.Planning
  alias ClinicDemo.Planning.{Lowering, RosterValidator, SnapshotBuilder}
  alias ClinicDemo.Planning.Models.WeeklyRoster

  @moduletag :solver

  defp prepared(w_fun) do
    team = team!()
    monday = next_monday()
    appointments = w_fun.(team, monday)

    %{model_version: mv, binding: binding} = Planning.Install.current!()

    {:ok, run} =
      Planning.request_run(%{binding_id: binding.id, model_version_id: mv.id}, actor: staff())

    {:ok, run} = SnapshotBuilder.prepare(run, week_start: monday)
    assert run.preparation_status == :prepared
    {:ok, payload} = SnapshotBuilder.problem_payload(run)
    %{team: team, monday: monday, appts: appointments, payload: payload}
  end

  # Both verdicts on a hand-written roster: {checker_correct?, validator_result}.
  defp verdicts(w, shifts, covers) do
    answer = fake_answer(w.payload, shifts, covers) |> Map.delete("obj")
    {:ok, decoded} = Lowering.decode(w.payload, answer)

    {checker_correct?(w.payload, answer), RosterValidator.validate(w.payload["problem"], decoded)}
  end

  defp checker_correct?(payload, answer) do
    problem = %Problem{
      model_path: WeeklyRoster.definition().checker_path,
      data: Map.merge(payload["data"], answer),
      limits: %{time_limit_ms: 20_000, memory_bytes: 1_000_000_000}
    }

    {:ok, session} = Backend.Solverl.start(problem, [])
    {:ok, result} = Backend.Solverl.await(session, 30_000)
    result.status == :feasible
  end

  defp codes({:error, violations}), do: violations |> Enum.map(& &1.code) |> Enum.uniq()

  defp two_overlapping(team, monday) do
    type = type!("Wellness exam")

    [
      book!(monday, 1, {10, 0}, team.vet, type: type),
      book!(monday, 1, {10, 15}, team.head_vet, type: type)
    ]
  end

  test "a valid roster is accepted by both" do
    w = prepared(&two_overlapping/2)
    [a1, a2] = w.appts

    shifts = [{w.team.vet.id, 1, "early"}, {w.team.head_vet.id, 1, "early"}]

    assert {true, :ok} =
             verdicts(w, shifts, [{a1.id, w.team.vet.id}, {a2.id, w.team.head_vet.id}])
  end

  test "two overlapping appointments for one vet are rejected by both" do
    w = prepared(&two_overlapping/2)
    [a1, a2] = w.appts

    {checker, validator} =
      verdicts(w, [{w.team.vet.id, 1, "early"}], [{a1.id, w.team.vet.id}, {a2.id, w.team.vet.id}])

    refute checker
    assert :overlap in codes(validator)
  end

  test "an exam attended by a nurse is rejected by both" do
    w = prepared(&two_overlapping/2)
    [a1, a2] = w.appts

    shifts = [{w.team.manager.id, 1, "early"}, {w.team.head_vet.id, 1, "early"}]

    {checker, validator} =
      verdicts(w, shifts, [{a1.id, w.team.manager.id}, {a2.id, w.team.head_vet.id}])

    refute checker
    assert :role_mismatch in codes(validator)
  end

  test "an appointment outside the clinician's shift is rejected by both" do
    w = prepared(&two_overlapping/2)
    [a1, a2] = w.appts

    shifts = [{w.team.vet.id, 2, "early"}, {w.team.head_vet.id, 1, "early"}]

    {checker, validator} =
      verdicts(w, shifts, [{a1.id, w.team.vet.id}, {a2.id, w.team.head_vet.id}])

    refute checker
    assert :outside_shift_window in codes(validator)
  end

  test "a shift through removed availability is rejected by both" do
    w =
      prepared(fn team, monday ->
        remove_availability!(monday, 1, team.vet, {8, 0}, {9, 0})
        two_overlapping(team, monday)
      end)

    [a1, a2] = w.appts

    shifts = [{w.team.vet.id, 1, "early"}, {w.team.head_vet.id, 1, "early"}]

    {checker, validator} =
      verdicts(w, shifts, [{a1.id, w.team.vet.id}, {a2.id, w.team.head_vet.id}])

    refute checker
    assert :shift_in_unavailable_window in codes(validator)
  end

  test "a shift filled past its reserve is rejected by both" do
    w =
      prepared(fn team, monday ->
        type = type!("Wellness exam")

        [
          book!(monday, 1, {8, 0}, team.vet, type: type, duration: 240),
          book!(monday, 1, {12, 0}, team.vet, type: type, duration: 240)
        ]
      end)

    [a1, a2] = w.appts

    {checker, validator} =
      verdicts(w, [{w.team.vet.id, 1, "early"}], [{a1.id, w.team.vet.id}, {a2.id, w.team.vet.id}])

    refute checker
    assert :reserve_violated in codes(validator)
  end

  test "a pattern the staffing policy does not allow that day is rejected by both" do
    w = prepared(&two_overlapping/2)
    [a1, a2] = w.appts

    # "weekend" is a Saturday-only pattern: on a Monday neither the template nor the
    # staffing policy allows it.
    shifts = [{w.team.vet.id, 1, "weekend"}, {w.team.head_vet.id, 1, "early"}]

    {checker, validator} =
      verdicts(w, shifts, [{a1.id, w.team.vet.id}, {a2.id, w.team.head_vet.id}])

    refute checker
    assert :shift_pattern_not_allowed in codes(validator)
  end
end
