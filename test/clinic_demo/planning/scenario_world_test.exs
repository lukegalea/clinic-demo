defmodule ClinicDemo.Planning.ScenarioWorldTest do
  @moduledoc """
  A candidate a scenario run proposed is never applied to the real schedule.

  The candidate's `world` is its run's, copied at `propose` and never an input; `apply`
  refuses a `:scenario` candidate with `scenario_world`, so taking a scenario's plan live
  is a new operational run, checked, approved and applied like any other. Every test
  goes in as a person or as machinery, from the outside.
  """

  use ClinicDemo.DataCase, async: false

  import ClinicDemo.PlanningFixtures

  alias ClinicDemo.Planning
  alias ClinicDemo.Planning.{FourEyes, Machinery, WeeklyRoster}
  alias ClinicDemo.Scheduling

  defp setup_week(opts) do
    team = team!()
    monday = next_monday()
    type = type!("Wellness exam")
    a1 = book!(monday, 1, {10, 0}, team.vet, type: type)

    script = fn _payload -> {[{team.vet.id, 1, "early"}], [{a1.id, team.vet.id}]} end
    {:ok, %{run: run, candidates: [candidate]}} = plan_fake(monday, staff(), script, opts)
    {:ok, _instance} = WeeklyRoster.submit_for_approval(candidate)

    %{team: team, run: run, candidate: candidate, tasks: FourEyes.tasks(candidate.id)}
  end

  defp as(clinician), do: %{id: clinician.id}

  defp scenario_week, do: setup_week(world: :scenario, scenario_ref: "what-if-1")

  test "a scenario candidate carries its run's world" do
    scenario = scenario_week()
    assert scenario.run.world == :scenario
    assert scenario.candidate.world == :scenario
  end

  test "an operational candidate carries the operational world" do
    assert setup_week([]).candidate.world == :operational
  end

  test "both approvers signing a scenario candidate does not apply it" do
    w = scenario_week()

    {:ok, _} = FourEyes.sign(w.tasks["ManagerSignoff"].id, :approved, as(w.team.manager))

    assert {:error, error} =
             FourEyes.sign(w.tasks["HeadVetSignoff"].id, :approved, as(w.team.head_vet))

    assert Exception.message(error) =~ "scenario_world"

    candidate = Ash.get!(Planning.Candidate, w.candidate.id, authorize?: false)
    refute candidate.disposition == :applied
    assert Scheduling.list_shifts!(authorize?: false) == []
    assert Scheduling.list_assignments!(authorize?: false) == []
  end

  test "applying a scenario candidate directly is refused, whoever asks" do
    w = scenario_week()

    for actor <- [as(w.team.head_vet), as(w.team.manager), Machinery.actor(), staff()] do
      assert {:error, error} = Planning.apply_candidate(w.candidate, %{}, actor: actor)
      assert Exception.message(error) =~ "scenario_world"
    end

    assert Scheduling.list_shifts!(authorize?: false) == []
    assert Scheduling.list_assignments!(authorize?: false) == []
  end

  test "the world is not an input of propose" do
    w = scenario_week()

    assert {:error, _} =
             Planning.propose_candidate(
               %{run_id: w.run.id, index: 7, assignments: "sealed", world: :operational},
               actor: Machinery.actor()
             )
  end

  test "an operational candidate still applies" do
    w = setup_week([])
    {:ok, _} = FourEyes.sign(w.tasks["ManagerSignoff"].id, :approved, as(w.team.manager))
    {:ok, applied} = FourEyes.sign(w.tasks["HeadVetSignoff"].id, :approved, as(w.team.head_vet))
    assert applied.disposition == :applied
  end
end
