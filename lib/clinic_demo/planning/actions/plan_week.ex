defmodule ClinicDemo.Planning.Actions.PlanWeek do
  @moduledoc """
  The `/roster` "Plan a week" report's implementation: plans the requested
  week as the acting person and returns the new run's candidates as row maps
  (best first), each row carrying its run's solve verdict.

  The week's Monday is the week containing `week_start`, so any day of the
  intended week works. The default is next week's Monday — the flagship
  tests' convention (`ClinicDemo.PlanningFixtures.next_monday/0`): bookings
  for a future week, not a week half spent.

  The solve runs in-process and synchronously (seconds on seeded weeks);
  a report invocation is a web request, so there is no queue in between.
  The requesting actor is the acting clinician from the actor plug — the
  same posture as `Run`'s `:request` action (any signed-in member of staff
  asks; the machinery does the solving), and a solve needs no machinery
  actor from the caller.
  """

  use Ash.Resource.Actions.Implementation

  alias ClinicDemo.Planning.WeeklyRoster

  @doc "The Monday of next week — the report's default `week_start`."
  @spec next_monday() :: Date.t()
  def next_monday do
    Date.utc_today() |> Date.beginning_of_week() |> Date.add(7)
  end

  @impl true
  def run(input, _opts, _context) do
    monday = Date.beginning_of_week(input.arguments.week_start)
    actor = input.context.private[:actor]

    case WeeklyRoster.plan(week_start: monday, actor: actor) do
      {:ok, %{run: run, candidates: candidates}} ->
        {:ok, Enum.map(candidates, &row(&1, run))}

      {:error, error} ->
        {:error, error}
    end
  end

  defp row(candidate, run) do
    %{
      index: candidate.index,
      check_status: candidate.check_status,
      disposition: candidate.disposition,
      freshness: candidate.freshness,
      run_id: candidate.run_id,
      solve_status: run.solve_status,
      complete?: run.complete?,
      optimality: run.optimality,
      outcome_reason: run.outcome_reason
    }
  end
end
