defmodule ClinicDemo.Planning.CheckPipeline do
  @moduledoc """
  Turns a solved run's candidates into checked `Candidate` rows.

      CheckPipeline.process(run, payload, backend_candidates) :: :ok | {:error, term}

  For every candidate the backend returned (best first):

    1. **propose** — `Candidate.propose` as the planner: the model's answer read
       back to domain-level assignments by `Lowering.decode/2` (shifts, covered
       appointments, uncovered ones), with the count of previously applied
       assignments it preserves, plus the unresolved obligations: one per
       uncovered appointment, as an id and a reason code, never a value.
    2. **MiniZinc checker** — the verdict the backend recorded while solving
       (`checker_ok`). When the backend recorded none, the checker model is run
       against the problem data plus the candidate's variables through the same
       backend: a proven `:infeasible` (the checker is UNSAT) is `INCORRECT`,
       an error is `:checker_failed`.
    3. **independent Elixir validator** — `ClinicDemo.Planning.RosterValidator`
       over the domain-level problem and the decoded assignments. It shares no
       code with the model, the checker or the lowering.
    4. **record** — a create-only `CheckResult` (the two verdicts, separately, as
       statuses and reason codes; the checker's output as a digest; violation
       details as JSON) and `Candidate.record_check` with the combined verdict:
       `:correct` only when both say so, `:incorrect` when either says so,
       `:checker_failed` / `:validator_failed` when a verdict could not be produced.

  A candidate that no check has proven `:correct` can never be approved
  (`Candidate.approve` requires it), so a model bug and a validator bug must
  coincide for a bad roster to reach a person.

  Idempotent per `(run_id, index)`: an existing candidate is not proposed again,
  and one already checked is left alone.
  """

  require Ash.Query

  alias AshPlanning.{Problem, SolveResult}
  alias ClinicDemo.Planning
  alias ClinicDemo.Planning.{Candidate, Lowering, Machinery, RosterValidator}
  alias ClinicDemo.Planning.Models.WeeklyRoster

  @doc """
  Options: `:backend` (the `AshPlanning.Backend` the checker run goes through when
  the solve recorded no verdict; default `AshPlanning.Backend.Solverl`) and
  `:checker_data` (extra problem data for a scripted backend's checker run; the
  real backend never gets any).
  """
  @spec process(struct(), map(), [map()], keyword()) :: :ok | {:error, term()}
  def process(run, payload, backend_candidates, opts \\ []) do
    backend_candidates
    |> Enum.sort_by(&(&1[:index] || 0), :desc)
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {candidate, position}, :ok ->
      case check_candidate(run, payload, candidate, position, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_candidate(run, payload, candidate, position, opts) do
    data = stringify(candidate[:data] || %{})

    with {:ok, assignments} <- Lowering.decode(payload, data),
         assignments = summarize(assignments, payload, candidate),
         {:ok, row} <- propose(run, position, assignments) do
      if row.check_status == :unchecked,
        do: verify(payload, row, candidate, assignments, data, opts),
        else: :ok
    else
      {:error, reason} -> {:error, {:candidate, position, reason}}
    end
  end

  # The decoded assignments plus what a person reading the candidate wants to know
  # without opening the model: how much of the applied plan it keeps.
  defp summarize(assignments, payload, candidate) do
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

  defp propose(run, position, assignments) do
    run_id = run.id

    Candidate
    |> Ash.Query.filter(run_id == ^run_id and index == ^position)
    |> Ash.read_one(actor: Machinery.actor())
    |> case do
      {:ok, nil} ->
        Planning.propose_candidate(
          %{
            run_id: run_id,
            index: position,
            assignments: Jason.encode!(assignments),
            unresolved_obligations:
              for id <- assignments["uncovered"] do
                %{"id" => id, "kind" => "appointment", "reason" => "uncovered"}
              end
          },
          actor: Machinery.actor()
        )

      {:ok, existing} ->
        {:ok, existing}

      {:error, error} ->
        {:error, error}
    end
  end

  defp verify(payload, row, candidate, assignments, data, opts) do
    {checker_status, checker_reason} = checker_verdict(candidate, payload, data, opts)
    {validator_status, validator_reason, details} = validator_verdict(payload, assignments)

    with {:ok, _result} <-
           Planning.record_check_result(
             %{
               candidate_id: row.id,
               checker_status: checker_status,
               checker_reason: checker_reason,
               validator_status: validator_status,
               validator_reason: validator_reason,
               checker_output_digest: digest(candidate[:checker_output]),
               violation_details: Jason.encode!(details)
             },
             actor: Machinery.actor()
           ),
         {:ok, _checked} <-
           Planning.record_candidate_check(
             row,
             %{check_status: combine(checker_status, validator_status)},
             actor: Machinery.actor()
           ) do
      :ok
    end
  end

  # ── the MiniZinc checker ───────────────────────────────────────────────────

  defp checker_verdict(%{checker_ok?: true}, _payload, _data, _opts),
    do: {:correct, "checker_accepted"}

  defp checker_verdict(%{checker_ok?: false}, _payload, _data, _opts),
    do: {:incorrect, "checker_rejected"}

  defp checker_verdict(_no_verdict, payload, data, opts) do
    definition = WeeklyRoster.definition()
    backend = Keyword.get(opts, :backend, AshPlanning.Backend.Solverl)
    extra = Keyword.get(opts, :checker_data, %{})

    problem = %Problem{
      model_path: definition.checker_path,
      data: payload["data"] |> Map.merge(data) |> Map.merge(extra),
      limits: %{time_limit_ms: 30_000, memory_bytes: 1_000_000_000}
    }

    with {:ok, session} <- backend.start(problem, []),
         {:ok, %SolveResult{status: status, outcome_reason: reason}} <-
           backend.await(session, 60_000) do
      case {status, reason} do
        {:feasible, _} -> {:correct, "checker_accepted"}
        {:infeasible, _} -> {:incorrect, "checker_unsatisfiable"}
        {:unknown, _} -> {:checker_failed, "checker_no_answer"}
      end
    else
      _ -> {:checker_failed, "checker_error"}
    end
  end

  # ── the independent validator ──────────────────────────────────────────────

  defp validator_verdict(payload, assignments) do
    case RosterValidator.validate(payload["problem"], assignments) do
      :ok ->
        {:correct, "validator_accepted", []}

      {:error, [%{code: code} | _] = violations} ->
        {:incorrect, Atom.to_string(code), Enum.map(violations, &violation_json/1)}
    end
  rescue
    error -> {:validator_failed, "validator_raised", [%{"error" => inspect(error.__struct__)}]}
  end

  defp violation_json(%{code: code, subject: subject, detail: detail}) do
    %{"code" => Atom.to_string(code), "subject" => subject, "detail" => stringify(detail)}
  end

  defp combine(:correct, :correct), do: :correct
  defp combine(:checker_failed, _), do: :checker_failed
  defp combine(_, :validator_failed), do: :validator_failed
  defp combine(_, _), do: :incorrect

  defp digest(nil), do: nil

  defp digest(output) when is_binary(output),
    do: :crypto.hash(:sha256, output) |> Base.encode16(case: :lower)

  defp digest(_other), do: nil

  # JSON-shaped: string keys, Decimals as strings.
  defp stringify(%Decimal{} = d), do: Decimal.to_string(d)

  defp stringify(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end
