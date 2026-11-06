defmodule ClinicDemo.Planning.MobileVisits do
  @moduledoc """
  One veterinarian's mobile visits for one day, end to end: ask for a route, read why
  a visit was refused, and send a candidate for the clinic manager's and head vet's
  sign-off. The same loop as `ClinicDemo.Planning.WeeklyRoster`, with a different
  model.

      {:ok, %{run: run, candidates: [best | _]}} =
        MobileVisits.plan(day: ~D[2026-11-10], clinician_id: vet.id, actor: dispatcher)

      {:ok, _instance} = MobileVisits.submit_for_approval(best)
      # ... the two approvers sign (ClinicDemo.Planning.FourEyes.sign/3);
      # the second signature books the visits.

  `plan/1` is `Run.request` (a person asks), then `SnapshotBuilder.prepare/2` (read
  the day `as_of` the knowledge cutoff, pin the travel matrix, seal the snapshot), then
  `SolveRunner.solve/2` (a backend solves, the check pipeline proposes and checks every
  candidate). Nothing in it changes the schedule: a candidate is inert until two people
  sign it and it is applied (`ClinicDemo.Planning.MobilePlan.apply_plan/3`).

  ## Three honest refusals

    * **Travel against commitments.** Every requested visit must fit its window with
      the travel into and out of it between the veterinarian's pinned commitments. One
      that fits its window but not the drive is **refused**: the run is `:infeasible`
      (proven, `complete?: true`) and no candidate exists. `refusals/1` says which
      visit and which commitment its travel runs into. It is never squeezed in.
    * **Unknown or unreachable travel.** A pair the matrix does not hold makes the run
      `:needs_input` naming the pair (`travel_pair:<from>:<to>`); a pair it marks
      unreachable is infeasible. Neither is ever zero.
    * **Inputs that cannot be planned** (a visit type that cannot be done away from the
      clinic, equipment the kit lacks, a commitment that overlaps another) make the run
      `:needs_input` naming each.

  A **replan** is just another `plan/1` for the same day and veterinarian: it reads
  whatever has been applied since (scheduled requests, their appointments, the
  commitments) and the model prefers to keep every booked visit where it is. Planning
  a day supersedes the earlier undecided candidates for it and closes their sign-off
  tasks. The veterinarian's in-clinic commitments are pinned in every plan: no plan,
  first or replan, can move them.

  The backend defaults to `AshPlanning.Backend.Solverl` (MiniZinc + Gecode under
  `prlimit`); tests pass `AshPlanning.Backend.Fake`.
  """

  require Ash.Query

  alias ClinicDemo.Planning

  alias ClinicDemo.Planning.{
    Candidate,
    FourEyes,
    Install,
    Machinery,
    MobileExplain,
    Run,
    SnapshotBuilder,
    SolveRunner
  }

  alias ClinicDemo.Planning.Models.MobileVisits, as: Model

  @doc """
  Plans `:day` (a `Date`, UTC) for the veterinarian `:clinician_id`. Required: `:day`,
  `:clinician_id`, `:actor` (the requesting member of staff).

  Other options: `:matrix_key` (the travel matrix, default `"clinic_van"`), `:cutoff`
  (the knowledge cutoff, default now), `:backend`, `:backend_data`, `:checker_data`,
  `:await_timeout` (see `ClinicDemo.Planning.SolveRunner`), `:world` (`:operational`,
  the default, or `:scenario` with `:scenario_ref`).

  Returns the run as it stands and its candidates, best first (empty when the run
  needs input, failed to prepare, is infeasible or has no answer).
  """
  @spec plan(keyword()) :: {:ok, %{run: struct(), candidates: [struct()]}} | {:error, term()}
  def plan(opts) do
    day = Keyword.fetch!(opts, :day)
    clinician_id = Keyword.fetch!(opts, :clinician_id)
    actor = Keyword.fetch!(opts, :actor)
    %{model_version: model_version, binding: binding} = Install.current!(Model)

    with {:ok, run} <-
           Planning.request_run(
             %{
               binding_id: binding.id,
               model_version_id: model_version.id,
               world: Keyword.get(opts, :world, :operational),
               scenario_ref: Keyword.get(opts, :scenario_ref)
             },
             actor: actor
           ),
         {:ok, run} <-
           SnapshotBuilder.prepare(
             run,
             Keyword.take(opts, [:day, :clinician_id, :matrix_key, :cutoff, :completeness])
           ),
         {:ok, run} <- solve(run, opts) do
      candidates = candidates(run)
      supersede_earlier(run, candidates, day, clinician_id)
      {:ok, %{run: run, candidates: candidates}}
    end
  end

  @doc "The run's candidates, best first (index 0)."
  @spec candidates(struct()) :: [struct()]
  def candidates(%Run{id: run_id}) do
    Candidate
    |> Ash.Query.filter(run_id == ^run_id)
    |> Ash.Query.sort(index: :asc)
    |> Ash.read!(actor: Machinery.actor())
  end

  @doc """
  Why each requested visit of a prepared run is (or would be) refused, when the run
  is `:infeasible`. See `ClinicDemo.Planning.MobileExplain`; `[]` for a run that is not
  infeasible.
  """
  @spec refusals(struct()) :: [map()]
  def refusals(%Run{solve_status: :infeasible} = run) do
    case SnapshotBuilder.problem_payload(run) do
      {:ok, payload} -> MobileExplain.refusals(payload["problem"])
      {:error, _} -> []
    end
  end

  def refusals(%Run{}), do: []

  @doc """
  Starts the four-eyes approval of a checked, current candidate: the manager's and
  the head vet's sign-off tasks. Refuses a candidate that is not `:correct`.
  """
  @spec submit_for_approval(struct()) :: {:ok, map()} | {:error, term()}
  def submit_for_approval(
        %Candidate{check_status: :correct, freshness: :current, disposition: :proposed} =
          candidate
      ),
      do: FourEyes.start(candidate)

  def submit_for_approval(%Candidate{}), do: {:error, :candidate_not_approvable}

  defp solve(%Run{preparation_status: :prepared} = run, opts) do
    SolveRunner.solve(
      run,
      Keyword.take(opts, [:backend, :backend_data, :checker_data, :await_timeout])
    )
  end

  defp solve(%Run{} = run, _opts), do: {:ok, run}

  # A newer plan for the same day and veterinarian replaces the earlier undecided
  # candidates: they were made against a schedule that has moved on. Their sign-off
  # tasks are closed.
  defp supersede_earlier(run, new_candidates, day, clinician_id) do
    if new_candidates != [] do
      scope = %{"day" => Date.to_iso8601(day), "clinician_id" => clinician_id}

      Candidate
      |> Ash.Query.filter(disposition in [:proposed, :approved] and run_id != ^run.id)
      |> Ash.Query.load(:run)
      |> Ash.read!(actor: Machinery.actor())
      |> Enum.filter(&(Map.take(&1.run.stats, Map.keys(scope)) == scope))
      |> Enum.each(fn candidate ->
        FourEyes.cancel(candidate.id)
        Planning.supersede_candidate!(candidate, %{}, actor: Machinery.actor())
      end)
    end

    :ok
  end
end
