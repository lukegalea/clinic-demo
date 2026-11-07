defmodule ClinicDemo.Planning.Actions.PlanWeekTest do
  @moduledoc """
  The "Plan a week" report's action.

  Two layers:

    * the argument default, pure — next week's Monday, the flagship fixtures'
      convention, so a plan is always asked for a week not half spent;
    * the pipeline, `:solver`-gated like FlagshipTest's real-solve variant: any
      signed-in member of staff may run it as the acting person, any day of the
      intended week is accepted, and the rows are the new run's candidates
      best-first, each carrying the run's solve verdict.
  """

  use ClinicDemo.DataCase, async: false

  import ClinicDemo.PlanningFixtures

  alias ClinicDemo.Planning.{Actions.PlanWeek, Install, Run}

  setup do
    ClinicDemo.BusinessEvents.install!()
    Install.install!()
    :ok
  end

  test "the week_start default is next week's Monday" do
    next_monday = PlanWeek.next_monday()

    assert next_monday == Date.utc_today() |> Date.beginning_of_week() |> Date.add(7)
    assert Date.compare(next_monday, Date.utc_today()) == :gt
  end

  @tag :solver
  test "planning a week as a person returns the run's candidates as rows" do
    team = team!()
    monday = next_monday()
    wellness = type!("Wellness exam")

    book!(monday, 1, {10, 0}, team.head_vet, type: wellness)
    book!(monday, 1, {11, 0}, team.head_vet, type: wellness)

    # Tuesday of the intended week: the action must plan that week's Monday.
    tuesday = Date.add(monday, 1)

    # Best first, possibly several: an open week has many optimal rosters and
    # the real solver proposes more than one (the flagship tests' [v1 | _]
    # posture). Only index 0 is "the" proposal.
    assert {:ok, [row | _]} =
             Run
             |> Ash.ActionInput.for_action(
               :plan_week,
               %{"week_start" => Date.to_iso8601(tuesday)},
               actor: staff()
             )
             |> Ash.run_action()

    assert row.index == 0
    assert row.check_status == :correct
    assert row.disposition == :proposed
    assert row.freshness == :current
    assert row.solve_status == :optimal
    assert row.complete? == true
    assert is_binary(row.run_id)

    # The run that produced the row planned the week containing the argument.
    run = Ash.get!(Run, row.run_id, authorize?: false)
    assert run.stats["week_start"] == Date.to_iso8601(monday)
  end
end
