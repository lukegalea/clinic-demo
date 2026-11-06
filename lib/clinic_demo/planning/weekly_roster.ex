defmodule ClinicDemo.Planning.WeeklyRoster do
  @moduledoc """
  The weekly staffing roster, end to end: ask for a plan, read how it was made,
  and send a candidate for the clinic manager's and head vet's sign-off.

      {:ok, %{run: run, candidates: [best | _]}} =
        WeeklyRoster.plan(week_start: ~D[2026-11-09], actor: manager)

      {:ok, explanations} = WeeklyRoster.explain(best)
      {:ok, _instance} = WeeklyRoster.submit_for_approval(best)
      # ... the two approvers sign (ClinicDemo.Planning.FourEyes.sign/3);
      # the second signature applies it.

  `plan/1` is `Run.request` (a person asks) then `SnapshotBuilder.prepare/2` (read
  the week `as_of` the knowledge cutoff, ask the pinned policy, seal the
  snapshot) then `SolveRunner.solve/2` (a backend solves, the check pipeline
  proposes and checks every candidate). Nothing in it changes the schedule: the
  solver never moves an appointment, and a candidate is inert until two people
  sign it and it is applied.

  A **replan** is just another `plan/1` for the same week: it reads whatever has
  been applied since (shifts and assignments become part of the snapshot) and the
  model prefers to keep every previously applied assignment that is still
  feasible. Planning a week supersedes the earlier undecided candidates for it, and
  closes their sign-off tasks.

  The backend defaults to `AshPlanning.Backend.Solverl` (MiniZinc + Gecode under
  `prlimit`); tests pass `AshPlanning.Backend.Fake`.
  """

  require Ash.Query

  alias ClinicDemo.BusinessEvents.Scenarios
  alias ClinicDemo.Planning

  alias ClinicDemo.Planning.{
    Candidate,
    Explain,
    FourEyes,
    Install,
    Machinery,
    ModelVersion,
    Run,
    SnapshotBuilder,
    SolveRunner
  }

  @doc """
  Plans the week starting `:week_start` (a Monday). Required: `:week_start`,
  `:actor` (the requesting member of staff).

  Other options: `:cutoff` (the knowledge cutoff, default now), `:backend`,
  `:backend_data`, `:checker_data`, `:await_timeout` (see
  `ClinicDemo.Planning.SolveRunner`), `:world` (`:operational`, the default, or
  `:scenario` with `:scenario_ref`).

  Returns the run as it stands and its candidates, best first (empty when the
  run needs input, failed to prepare, or has no answer).
  """
  @spec plan(keyword()) :: {:ok, %{run: struct(), candidates: [struct()]}} | {:error, term()}
  def plan(opts) do
    week_start = Keyword.fetch!(opts, :week_start)
    actor = Keyword.fetch!(opts, :actor)
    %{model_version: model_version, binding: binding} = Install.current!()

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
           SnapshotBuilder.prepare(run, Keyword.take(opts, [:week_start, :cutoff, :completeness])),
         {:ok, run} <- solve(run, opts) do
      candidates = candidates(run)
      supersede_earlier(run, candidates, week_start)
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
  Why each appointment of the candidate's run is covered the way it is, or why it
  is not covered. See `ClinicDemo.Planning.Explain`.
  """
  @spec explain(struct()) :: {:ok, [Explain.explanation()]} | {:error, term()}
  def explain(%Candidate{} = candidate) do
    with {:ok, run} <- Ash.get(Run, candidate.run_id, actor: Machinery.actor()) do
      Explain.explain(candidate, run)
    end
  end

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

  @doc """
  Evaluates a candidate on the **simulation twin**: a scenario draw whose identity is
  `(candidate_id, snapshot_digest, model_hash, random_stream_id, replication_id)`
  (`ClinicDemo.BusinessEvents.Scenarios`). Every simulated event lands in the twin
  (`business_event_simulation_events`) and folds into the separate sim value
  projection; the real ledger and projection are never touched, and the result is
  labelled `simulated?: true` for any surface that shows it.

  Options: `:random_stream_id` (default `"default"`), `:replication_id` (default 0),
  and `Scenarios.generate!/1`'s `:multiplier`, `:horizon_weeks`, `:label`.
  """
  @spec simulate(struct(), keyword()) :: map()
  def simulate(%Candidate{} = candidate, opts \\ []) do
    run = Ash.get!(Run, candidate.run_id, actor: Machinery.actor())
    model_version = Ash.get!(ModelVersion, run.model_version_id, actor: Machinery.actor())

    identity = [
      candidate_id: candidate.id,
      snapshot_digest: run.snapshot_digest,
      model_hash: model_version.model_sha256,
      random_stream_id: Keyword.get(opts, :random_stream_id, "default"),
      replication_id: Keyword.get(opts, :replication_id, 0)
    ]

    (identity ++ Keyword.take(opts, [:multiplier, :horizon_weeks, :label]))
    |> Scenarios.generate!()
    |> Map.put(:simulated?, true)
  end

  defp solve(%Run{preparation_status: :prepared} = run, opts) do
    SolveRunner.solve(
      run,
      Keyword.take(opts, [:backend, :backend_data, :checker_data, :await_timeout])
    )
  end

  defp solve(%Run{} = run, _opts), do: {:ok, run}

  # A newer plan for the same week replaces the earlier undecided candidates: they
  # were made against a schedule that has moved on. Their sign-off tasks are closed.
  defp supersede_earlier(run, new_candidates, week_start) do
    if new_candidates != [] do
      week = Date.to_iso8601(week_start)

      Candidate
      |> Ash.Query.filter(disposition in [:proposed, :approved] and run_id != ^run.id)
      |> Ash.Query.load(:run)
      |> Ash.read!(actor: Machinery.actor())
      |> Enum.filter(&(&1.run.stats["week_start"] == week))
      |> Enum.each(fn candidate ->
        FourEyes.withdraw(candidate.id)
        Planning.supersede_candidate!(candidate, %{}, actor: Machinery.actor())
      end)
    end

    :ok
  end
end
