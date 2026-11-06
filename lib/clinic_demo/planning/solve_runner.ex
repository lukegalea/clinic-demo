defmodule ClinicDemo.Planning.SolveRunner do
  @moduledoc """
  Solves a `:prepared` run through an `AshPlanning.Backend` and records what came
  back, then hands the candidates to `ClinicDemo.Planning.CheckPipeline`.

      SolveRunner.solve(run, backend: AshPlanning.Backend.Solverl) :: {:ok, run} | {:error, term}

  Steps, each a planner (`Machinery`) write on the run:

    1. `Run.start` takes the lease (and bumps its epoch).
    2. The model and checker files are resolved from `priv/planning` and **their
       SHA-256 must equal the pinned `ModelVersion`'s**: a model edited after it
       was published is refused (`:model_hash_mismatch`), never silently run.
    3. The backend solves the bounded problem under the version's declared limits.
       The Solverl backend refuses to run without `prlimit` and never kills by name.
    4. `Run.record_result` records the outcome on the separate axes, fenced by the
       lease epoch. The honest-outcome rules are the backend's and the fragment's:
       `:infeasible` only when UNSAT was proven, a timeout with an incumbent is
       `:feasible` with `complete?: false`, `optimality: :optimal` only on a solver
       certificate.
    5. For `:optimal` and `:feasible` outcomes, the check pipeline proposes and
       checks every candidate.

  The objective and bound are decimals and live inside the result payload, never in
  a clear column.

  ## Options

    * `:backend` — an `AshPlanning.Backend` module (default
      `AshPlanning.Backend.Solverl`).
    * `:backend_data` — extra problem data, or a function from the decoded problem
      payload to it. Only meaningful to a scripted backend such as
      `AshPlanning.Backend.Fake`; the real backend would pass it to MiniZinc.
    * `:checker_data` — extra problem data for a scripted backend's checker run
      (same shape as `:backend_data`).
    * `:await_timeout` — milliseconds to wait for the backend (default 120_000).
  """

  require Logger

  alias AshPlanning.{Error, Problem, SolveResult}
  alias ClinicDemo.Planning

  alias ClinicDemo.Planning.{CheckPipeline, Machinery, ModelVersion, SnapshotBuilder}
  alias ClinicDemo.Planning.Models.WeeklyRoster

  @recordable_reasons [
    :time_limit,
    :solution_timeout,
    :fzn_timeout,
    :memory_limit,
    :resource_governor_unavailable,
    :model_missing,
    :backend_error
  ]

  @spec solve(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def solve(run, opts \\ []) do
    backend = Keyword.get(opts, :backend, AshPlanning.Backend.Solverl)
    timeout = Keyword.get(opts, :await_timeout, 120_000)

    with {:ok, payload} <- SnapshotBuilder.problem_payload(run),
         {:ok, version} <- Ash.get(ModelVersion, run.model_version_id, authorize?: false),
         {:ok, problem} <- problem(version, payload, opts),
         {:ok, started} <- start(run, backend) do
      outcome = run_backend(backend, problem, timeout)
      finish(started, outcome, payload, opts)
    end
  end

  # ── start / backend ────────────────────────────────────────────────────────

  defp start(run, backend) do
    Planning.start_run(
      run,
      %{backend: %{"name" => inspect(backend)}, session_pid: inspect(self())},
      actor: Machinery.actor()
    )
  end

  defp problem(version, payload, opts) do
    definition = WeeklyRoster.definition()

    if version.model_sha256 == sha256_file(definition.model_path) and
         version.checker_sha256 == sha256_file(definition.checker_path) do
      extra =
        case Keyword.get(opts, :backend_data) do
          nil -> %{}
          fun when is_function(fun, 1) -> fun.(payload)
          %{} = data -> data
        end

      {:ok,
       %Problem{
         model_path: definition.model_path,
         checker_path: definition.checker_path,
         data: Map.merge(payload["data"], extra),
         limits: limits(version.backend_profile),
         solver: version.backend_profile["solver"] || "gecode"
       }}
    else
      {:error, :model_hash_mismatch}
    end
  end

  defp limits(profile) do
    %{
      time_limit_ms: profile["time_limit_ms"],
      solution_timeout_ms: profile["solution_timeout_ms"],
      memory_bytes: profile["memory_bytes"]
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp run_backend(backend, problem, timeout) do
    with {:ok, session} <- backend.start(problem, []) do
      backend.await(session, timeout)
    end
  end

  defp sha256_file(path) do
    case File.read(path) do
      {:ok, binary} -> :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
      {:error, _} -> nil
    end
  end

  # ── recording ──────────────────────────────────────────────────────────────

  defp finish(run, {:ok, %SolveResult{} = result}, payload, opts) do
    axes = axes(result)

    attrs =
      Map.merge(axes, %{
        result_payload:
          Jason.encode!(%{"candidates" => Enum.map(candidates(result), &encode_candidate/1)}),
        stats:
          Map.merge(run.stats, Map.new(result.stats, fn {k, v} -> {to_string(k), stat(v)} end))
      })

    with {:ok, recorded} <-
           Planning.record_run_result(run, Map.put(attrs, :epoch, run.lease_epoch),
             actor: Machinery.actor()
           ) do
      outcome =
        if recorded.solve_status in [:optimal, :feasible],
          do:
            CheckPipeline.process(
              recorded,
              payload,
              candidates(result),
              check_opts(opts, payload)
            ),
          else: :no_answer

      emit_lineage(recorded, payload, if(outcome == :ok, do: :complete, else: :fail))
      {:ok, recorded}
    end
  end

  defp finish(run, {:error, %Error{} = error}, payload, _opts) do
    # The backend's message can quote the model's own diagnostics: it goes to the
    # log for an operator, never into a column.
    Logger.warning("planning run #{run.id} failed: #{error.kind}: #{error.message}")

    status = if error.kind == :invalid_model, do: :invalid_model, else: :backend_failed

    reason =
      case error.kind do
        :resource_governor_unavailable -> :resource_governor_unavailable
        :resource_exhausted -> :memory_limit
        _ -> :backend_error
      end

    emit_lineage(run, payload, :fail)

    Planning.record_run_result(
      run,
      %{
        solve_status: status,
        complete?: false,
        optimality: :none,
        outcome_reason: reason,
        epoch: run.lease_epoch,
        stats: Map.put(run.stats, "error_kind", Atom.to_string(error.kind))
      },
      actor: Machinery.actor()
    )
  end

  # One OpenLineage run per solve/check job (`planning` / `solve_check`), carrying
  # ONLY the digest facet: digest, purpose, input count, definition kinds. Never actor,
  # input values or tenant. Observational: a transport or facet problem is logged and
  # never undoes a recorded result.
  defp emit_lineage(run, payload, type) do
    with {:ok, snapshot} <- SnapshotBuilder.snapshot_from_payload(payload) do
      opts =
        [
          event_type: type,
          job_namespace: "planning",
          job_name: "solve_check",
          inputs: [],
          outputs: [],
          producer_name: "planning.solve_check",
          run_id: AshOpenLineage.run_id(run.id, "planning", "solve_check"),
          correlation_id: run.id
        ] ++ if(type == :fail, do: [error_message: "solve_check_failed"], else: [])

      event =
        opts
        |> AshOpenLineage.Event.run_event()
        |> put_in(
          ["run", "facets", AshOpenLineage.Event.snapshot_facet_name()],
          AshOpenLineage.Event.snapshot_facet(snapshot)
        )

      AshOpenLineage.Transport.dispatch(AshOpenLineage.transport(), event, %{})
    end
  rescue
    error -> Logger.warning("planning lineage emit failed: #{Exception.message(error)}")
  end

  defp check_opts(opts, payload) do
    checker_data =
      case Keyword.get(opts, :checker_data) do
        nil -> %{}
        fun when is_function(fun, 1) -> fun.(payload)
        %{} = data -> data
      end

    [
      backend: Keyword.get(opts, :backend, AshPlanning.Backend.Solverl),
      checker_data: checker_data
    ]
  end

  # The solve axes. `:optimal` only on the backend's optimality certificate.
  defp axes(%SolveResult{status: :infeasible}),
    do: %{solve_status: :infeasible, complete?: true, optimality: :none}

  defp axes(%SolveResult{status: :unknown} = r),
    do: %{solve_status: :unknown, complete?: false, optimality: :none, outcome_reason: reason(r)}

  defp axes(%SolveResult{status: :feasible, complete?: true, optimality: :proven}),
    do: %{solve_status: :optimal, complete?: true, optimality: :optimal}

  defp axes(%SolveResult{status: :feasible, complete?: complete?} = r),
    do: %{
      solve_status: :feasible,
      complete?: complete?,
      optimality: :none,
      outcome_reason: reason(r)
    }

  defp reason(%SolveResult{outcome_reason: reason}) when reason in @recordable_reasons, do: reason
  defp reason(_result), do: nil

  defp candidates(%SolveResult{payload: %{candidates: list}}), do: list
  defp candidates(_result), do: []

  # A candidate as stored: the objective (a Decimal) as a string, never a float.
  defp encode_candidate(candidate) do
    %{
      "index" => candidate[:index],
      "data" => candidate[:data],
      "objective" => candidate[:objective] && Decimal.to_string(candidate[:objective]),
      "checker_output" => candidate[:checker_output],
      "checker_ok" => candidate[:checker_ok?]
    }
  end

  defp stat(v) when is_atom(v) or is_number(v) or is_binary(v), do: v
  defp stat(v), do: inspect(v)
end
