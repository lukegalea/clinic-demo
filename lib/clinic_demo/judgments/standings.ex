defmodule ClinicDemo.Judgments.Standings do
  @moduledoc """
  The standings read: what the judgment record said AS OF an instant.

  `AshJudgments.Query.status/4` and `tri_state/4` are the as-of-now reads.
  This module is their as-of variant over the clinic's temporal facts host:
  the same tri-state lattice, evaluated against the fact versions the
  period containment selects at T — so "was this patient's acuity admitted
  as urgent at 14:00?" is a read, not a reconstruction. Where the digest
  timeline (the C2 capability, proven in vpm_poc) would answer
  "was the evidence still current at T?", the period axis answers "which
  admission was in force at T?" — the standing the surfaces show is this
  one.

  The lattice mirrors `AshJudgments.Query.status/4` (the package decides
  from a facts list it reads at now; the as-of read happens here, so the
  decision runs host-side against the same rules):

    * the grade floor applies at T (`:min_grade`, default `:grant`);
    * expiry is evaluated AT T — a licence that had not expired at T is
      not expired there, one that had is `{:unknown, :expired}`;
    * `holds` decides in/out exactly as the package does;
    * staleness is a `:current_digests` question (digest-at-T vs the
      recorded digest) and only applies when the caller supplies the
      timeline — the clinic does not keep digest periods, so the option
      exists to keep the lattice complete, not because this host feeds it.

  The tests pin the as-of-now equivalence: `status_at/4` at the present
  agrees with `AshJudgments.Query.status/4` on every verdict class.
  """

  alias ClinicDemo.Judgments.Fact
  alias ClinicDemo.Judgments.Triage

  @type verdict :: {:in, map()} | {:out, map()} | {:unknown, atom()}

  @doc """
  The three-valued acuity standing of ONE subject as of `as_of` —
  `{:in | :out | :unknown, fact_or_reason}`, the reason classes matching
  `AshJudgments.Query.status/4`'s.
  """
  @spec acuity_status_at(term(), DateTime.t(), keyword()) :: verdict()
  def acuity_status_at(subject, as_of, opts \\ []) do
    status_at(subject, Triage.question_id(), as_of, opts)
  end

  @doc """
  The three-valued standing of ONE subject under ONE predicate as of
  `as_of`.

  Options: `:min_grade` (`:grant` default), `:scope` (nil default —
  subject-alone facts), `:current_digests` (`%{subject => digest}`; only
  when the caller keeps a digest timeline).
  """
  @spec status_at(term(), String.t(), DateTime.t(), keyword()) :: verdict()
  def status_at(subject, predicate, as_of, opts \\ []) do
    Fact
    |> Ash.Query.for_read(:for_subject, %{subject: subject, predicate: predicate})
    |> Ash.Query.as_of(as_of)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&in_scope?(&1, opts))
    |> decide(opts, subject, as_of)
  end

  @doc """
  The three-valued partition over a list of subjects under ONE predicate
  as of `as_of` — `%{in: [...], out: [...], unknown: [{subject, reason}]}`,
  disjoint and covering, like `AshJudgments.Query.tri_state/4`.
  """
  @spec tri_state_at([term()], String.t(), DateTime.t(), keyword()) :: %{
          in: [term()],
          out: [term()],
          unknown: [{term(), atom()}]
        }
  def tri_state_at(subjects, predicate, as_of, opts \\ []) do
    Enum.reduce(subjects, %{in: [], out: [], unknown: []}, fn subject, acc ->
      case status_at(subject, predicate, as_of, opts) do
        {:in, _fact} -> %{acc | in: [subject | acc.in]}
        {:out, _fact} -> %{acc | out: [subject | acc.out]}
        {:unknown, reason} -> %{acc | unknown: [{subject, reason} | acc.unknown]}
      end
    end)
    |> Map.new(fn {partition, members} ->
      {partition, members |> Enum.reverse() |> Enum.sort()}
    end)
  end

  ## The lattice — mirrors AshJudgments.Query.decide/3 with the instant
  ## threaded where the package reads the clock (expiry) and where the C2
  ## digest timeline would sit (staleness).

  defp decide([], _opts, _subject, _as_of), do: {:unknown, :no_fact}

  defp decide(candidates, opts, subject, as_of) do
    min_grade = Keyword.get(opts, :min_grade, :grant)
    current_digest = opts |> Keyword.get(:current_digests, %{}) |> Map.get(subject)

    candidates
    |> Enum.map(fn fact ->
      cond do
        not AshJudgments.Facts.grade_at_least?(fact.admission_grade, min_grade) ->
          {:unknown, :below_grade}

        stale?(fact, current_digest) ->
          {:unknown, :stale}

        expired_at?(fact, as_of) ->
          {:unknown, :expired}

        fact.holds == true ->
          {:in, fact}

        fact.holds == false ->
          {:out, fact}

        true ->
          {:unknown, :no_fact}
      end
    end)
    |> Enum.sort_by(&grade_rank/1)
    |> Enum.find(& &1) || {:unknown, :no_fact}
  end

  defp stale?(fact, current_digest),
    do:
      not is_nil(fact.subject_state_digest) and not is_nil(current_digest) and
        fact.subject_state_digest != current_digest

  # Expiry at T, not at the wall clock: the as-of read's honest twin of the
  # fragment's `expired?` calculation (which evaluates at now).
  defp expired_at?(fact, as_of),
    do: fact.valid_until != nil and DateTime.compare(fact.valid_until, as_of) != :gt

  # Same scope rule as the package: a fact holds in a NARROWER scope than
  # the asked one when every asked key agrees; scope-less facts serve
  # scope-less reads.
  defp in_scope?(fact, opts) do
    scope = Keyword.get(opts, :scope)

    fact.scope == scope ||
      (is_map(scope) and is_map(fact.scope) and scope_subset?(fact.scope, scope))
  end

  defp scope_subset?(fact_scope, asked) do
    Enum.all?(asked, fn {k, v} ->
      Map.get(fact_scope, k) == v or Map.get(fact_scope, to_string(k)) == v
    end)
  end

  defp grade_rank({:in, fact}), do: grade_rank_of(fact.admission_grade)
  defp grade_rank({:out, fact}), do: grade_rank_of(fact.admission_grade)
  defp grade_rank({:unknown, _reason}), do: 0
  defp grade_rank_of(:person), do: 2
  defp grade_rank_of(:grant), do: 1
end
