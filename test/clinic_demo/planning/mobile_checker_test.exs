defmodule ClinicDemo.Planning.MobileCheckerTest do
  @moduledoc """
  The MiniZinc solution checker and the independent validator, side by side, on
  deliberately corrupted routes. Each case is built from a real prepared run's payload,
  so the data is exactly what the model is given.

  A corrupted route must be rejected by BOTH: the checker (UNSAT when run against the
  candidate's variables, which the Solverl backend reports as `:infeasible`) and the
  validator (a violation with the right code). One agreeing and the other not would be
  the signal that the model's lowering and the validator disagree about what a route
  means.

  The cast: the vet sees a patient in the clinic 10:00-10:30; farm A is 20 minutes from
  the clinic; working hours 08:00-18:00. Needs MiniZinc (`:solver`); skipped without it.
  """

  use ClinicDemo.DataCase, async: false

  import ClinicDemo.MobileFixtures
  import ClinicDemo.PlanningFixtures, only: [staff: 0, next_monday: 0]

  alias AshPlanning.{Backend, Problem}
  alias ClinicDemo.Planning
  alias ClinicDemo.Planning.{MobileLowering, MobileValidator, SnapshotBuilder}
  alias ClinicDemo.Planning.Models.MobileVisits
  alias ClinicDemo.Scheduling

  @moduletag :solver

  # A prepared run for one visit in `window`. Options: `:setup` (a function from the
  # cast, run before the matrix is published and the run prepared) and `:matrix`
  # (overrides for `publish_matrix!/3`).
  defp prepared(window, opts \\ []) do
    vet = mobile_vet!()
    places = places!()
    monday = next_monday()

    Keyword.get(opts, :setup, fn _cast -> :ok end).(%{vet: vet, monday: monday})
    publish_matrix!(places, "clinic_van", Keyword.get(opts, :matrix, %{}))
    in_clinic!(monday, {10, 0}, vet)
    {from, to} = window
    visit = request_visit!(monday, from, to, places.a)

    %{model_version: mv, binding: binding} = Planning.Install.current!(MobileVisits)

    {:ok, run} =
      Planning.request_run(%{binding_id: binding.id, model_version_id: mv.id}, actor: staff())

    {:ok, run} = SnapshotBuilder.prepare(run, day: monday, clinician_id: vet.id)
    assert run.preparation_status == :prepared
    {:ok, payload} = SnapshotBuilder.problem_payload(run)
    %{visit: visit, payload: payload}
  end

  # Both verdicts on a hand-written route: {checker_correct?, validator_result}.
  defp verdicts(w, start) do
    answer = fake_answer(w.payload, %{w.visit.id => start})
    {:ok, decoded} = MobileLowering.decode(w.payload, answer)

    {checker_correct?(w.payload, answer), MobileValidator.validate(w.payload["problem"], decoded)}
  end

  defp checker_correct?(payload, answer) do
    problem = %Problem{
      model_path: MobileVisits.definition().checker_path,
      data: Map.merge(payload["data"], answer),
      limits: %{time_limit_ms: 20_000, memory_bytes: 1_000_000_000}
    }

    {:ok, session} = Backend.Solverl.start(problem, [])
    {:ok, result} = Backend.Solverl.await(session, 30_000)
    result.status == :feasible
  end

  defp codes({:error, violations}), do: violations |> Enum.map(& &1.code) |> Enum.uniq()

  test "routes with the drive on either side of the commitment are accepted by both" do
    w = prepared({{8, 0}, {14, 0}})
    # After: 10:30 + 20 minutes of driving = 10:50.
    assert {true, :ok} = verdicts(w, {10, 50})
    # Before: 08:00 + 20 minutes out, and 09:00 + 20 minutes back for the 10:00 commitment.
    assert {true, :ok} = verdicts(w, {8, 30})
  end

  test "a visit squeezed in without its drive is rejected by both" do
    w = prepared({{10, 0}, {14, 0}})
    {checker, validator} = verdicts(w, {10, 35})

    refute checker
    assert :insufficient_travel in codes(validator)
  end

  test "a visit overlapping the commitment is rejected by both" do
    w = prepared({{10, 0}, {14, 0}})
    {checker, validator} = verdicts(w, {10, 15})

    refute checker
    assert :overlap in codes(validator)
  end

  test "a visit before its window opens is rejected by both" do
    w = prepared({{11, 0}, {14, 0}})
    {checker, validator} = verdicts(w, {10, 50})

    refute checker
    assert :outside_window in codes(validator)
  end

  test "a visit that ends after its window closes is rejected by both" do
    w = prepared({{10, 0}, {12, 0}})
    {checker, validator} = verdicts(w, {11, 45})

    refute checker
    assert :outside_window in codes(validator)
  end

  test "a route that gets the vet home after working hours is rejected by both" do
    w = prepared({{17, 30}, {19, 0}})
    {checker, validator} = verdicts(w, {17, 45})

    refute checker
    assert :outside_work_hours in codes(validator)
  end

  test "service inside removed availability is rejected by both" do
    w =
      prepared({{12, 0}, {14, 0}},
        setup: &remove_availability!(&1.monday, &1.vet, {12, 0}, {13, 0})
      )

    {checker, validator} = verdicts(w, {12, 10})

    refute checker
    assert :in_blocked_time in codes(validator)
  end

  test "a drive through removed availability is rejected by both" do
    w =
      prepared({{12, 0}, {14, 30}},
        setup: &remove_availability!(&1.monday, &1.vet, {12, 30}, {13, 10})
      )

    # Service [13:10, 13:40) is clear of the block; the drive [12:50, 13:10) is not.
    {checker, validator} = verdicts(w, {13, 10})

    refute checker
    assert :travel_in_blocked_time in codes(validator)
  end

  test "a route that needs an unreachable leg is rejected by both, never priced at zero" do
    w = prepared({{10, 0}, {14, 0}}, matrix: %{{:clinic, :a} => :unreachable})
    {checker, validator} = verdicts(w, {10, 50})

    refute checker
    assert :unreachable_leg in codes(validator)
  end

  defp remove_availability!(monday, vet, {from_h, from_m}, {to_h, to_m}) do
    Scheduling.declare_availability!(
      %{
        clinician_id: vet.id,
        starts_at: DateTime.new!(monday, Time.new!(from_h, from_m, 0), "Etc/UTC"),
        ends_at: DateTime.new!(monday, Time.new!(to_h, to_m, 0), "Etc/UTC"),
        available: false,
        reason: "leave"
      },
      actor: staff()
    )
  end
end
