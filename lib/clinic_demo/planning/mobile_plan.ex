defmodule ClinicDemo.Planning.MobilePlan do
  @moduledoc """
  The mobile-visits plan's side of the planning loop: the `ClinicDemo.Planning.Model`
  callbacks of `ClinicDemo.Planning.Models.MobileVisits`.

    * `build/4` reads one veterinarian's day (`ClinicDemo.Planning.MobileReader`,
      `as_of` the cutoff) and lowers it (`ClinicDemo.Planning.MobileLowering`)
      alongside the domain-level problem the independent validator reads;
    * `decode/2`, `summarize/3`, `obligations/1` and `validate/2` read a model answer
      back to stops and legs, say how much of the applied plan it keeps, and check it
      with `MobileValidator`. A mobile plan leaves nothing unresolved: every request
      is placed or the run is `:infeasible`, so `obligations/1` is empty;
    * `current_inputs/1` and `apply_plan/3` are `Candidate.apply`: the day's inputs as
      they are now, and the writes, as the approving person: each unscheduled request
      is booked as a **mobile `Appointment`** and marked scheduled, each already
      scheduled one whose start moved is rescheduled, the rest are left alone (and
      counted as preserved). Pinned commitments (the in-clinic work) are never
      touched: they are not part of the plan, only of what it works around.
  """

  alias AshOpenLineage.Snapshot.Definition
  alias ClinicDemo.Planning.Checks.AppliedByCandidate
  alias ClinicDemo.Planning.{MobileLowering, MobileReader, MobileValidator}
  alias ClinicDemo.Scheduling

  @default_matrix_key "clinic_van"

  @doc "The matrix a plan reads unless told otherwise."
  @spec default_matrix_key() :: String.t()
  def default_matrix_key, do: @default_matrix_key

  # ── scope / build ──────────────────────────────────────────────────────────

  @doc "What a mobile plan is about: one veterinarian's day."
  @spec scope(keyword()) :: map()
  def scope(opts) do
    %{
      "day" => Date.to_iso8601(Keyword.fetch!(opts, :day)),
      "clinician_id" => Keyword.fetch!(opts, :clinician_id)
    }
  end

  @doc """
  Reads and lowers the day named by `:day` for the veterinarian `:clinician_id` (both
  required) as of `cutoff`, with the travel matrix named by `:matrix_key` (default
  `"clinic_van"`). The lowered body is `nil` when an input is unresolved: nothing is
  solved for a day that cannot be planned as it stands.
  """
  @spec build(struct(), keyword(), DateTime.t(), [Definition.t()]) ::
          {:ok, ClinicDemo.Planning.Model.built()} | {:error, term()}
  def build(_run, opts, cutoff, _definitions) do
    day = Keyword.fetch!(opts, :day)
    clinician_id = Keyword.fetch!(opts, :clinician_id)
    matrix_key = Keyword.get(opts, :matrix_key, @default_matrix_key)

    with {:ok, facts} <- MobileReader.read(day, clinician_id, cutoff, matrix_key: matrix_key) do
      build_from(facts)
    end
  end

  defp build_from(facts) do
    {inputs, reasons} = MobileReader.inputs_with_reasons(facts)

    built = %{
      effective_at: facts.effective_at,
      inputs: inputs,
      reasons: reasons,
      stats: stats(facts),
      body: nil
    }

    if Enum.all?(inputs, &(&1.status == :value)) do
      lowered_body(facts, built)
    else
      {:ok, built}
    end
  end

  defp lowered_body(facts, built) do
    case MobileLowering.lower(facts) do
      {:ok, lowered} ->
        {:ok, %{built | body: Map.put(lowered, "problem", validator_problem(facts))}}

      {:error, _reason} = error ->
        error
    end
  end

  defp stats(facts) do
    base = %{
      "day" => Date.to_iso8601(facts.day),
      "clinician_id" => facts.clinician.id,
      "visits" => length(facts.visits),
      "commitments" => length(facts.commitments),
      "matrix_key" => facts.matrix_key
    }

    case facts.matrix do
      nil -> base
      matrix -> Map.put(base, "matrix_version", matrix.version)
    end
  end

  # The domain-level problem the independent validator reads. Instants are
  # ISO-8601, durations are minutes, places are ids: nothing here is a minute index
  # or a model node.
  defp validator_problem(facts) do
    involved = MapSet.new(facts.involved_locations)

    %{
      "day" => Date.to_iso8601(facts.day),
      "clinician_id" => facts.clinician.id,
      "matrix_key" => facts.matrix_key,
      "work_from" => DateTime.to_iso8601(facts.work_window.from),
      "work_to" => DateTime.to_iso8601(facts.work_window.to),
      "start_location_id" => facts.start_location_id,
      "end_location_id" => facts.end_location_id,
      "visits" =>
        for v <- facts.visits do
          %{
            "id" => v.id,
            "window_from" => DateTime.to_iso8601(v.window_from),
            "window_to" => DateTime.to_iso8601(v.window_to),
            "booked_minutes" => v.booked_minutes,
            "service_minutes" => v.service_minutes,
            "location_id" => v.location_id,
            "previous_starts_at" =>
              v.previous_starts_at && DateTime.to_iso8601(v.previous_starts_at)
          }
        end,
      "commitments" =>
        for c <- facts.commitments do
          %{
            "id" => c.id,
            "starts_at" => DateTime.to_iso8601(c.starts_at),
            "ends_at" => DateTime.to_iso8601(c.ends_at),
            "location_id" => c.location_id
          }
        end,
      "blocked" =>
        for b <- facts.blocks do
          %{
            "id" => b.id,
            "kind" => Atom.to_string(b.kind),
            "starts_at" => DateTime.to_iso8601(b.starts_at),
            "ends_at" => DateTime.to_iso8601(b.ends_at)
          }
        end,
      "travel" =>
        for {{from, to}, pair} <- facts.matrix.pairs,
            MapSet.member?(involved, from) and MapSet.member?(involved, to) do
          %{"from" => from, "to" => to, "reachable" => pair.reachable, "minutes" => pair.minutes}
        end
    }
  end

  # ── reading an answer ──────────────────────────────────────────────────────

  @doc "A model answer read back to stops and legs."
  @spec decode(map(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate decode(payload, answer), to: MobileLowering

  @doc """
  The decoded route plus what a person reading the candidate wants to know without
  opening the model: how many of the already-booked visits keep their start.
  """
  @spec summarize(map(), map(), map()) :: map()
  def summarize(assignments, payload, candidate) do
    previous = for v <- payload["problem"]["visits"], v["previous_starts_at"], do: v

    kept =
      Enum.count(previous, fn v ->
        Enum.any?(assignments["stops"], fn stop ->
          stop["visit_request_id"] == v["id"] and
            same_instant?(stop["starts_at"], v["previous_starts_at"])
        end)
      end)

    assignments
    |> Map.put("previous_visits", length(previous))
    |> Map.put("preserved_visits", kept)
    |> Map.put("moved_visits", length(previous) - kept)
    |> Map.put("objective", candidate[:objective] && Decimal.to_string(candidate[:objective]))
  end

  defp same_instant?(a, b) do
    with {:ok, a, _} <- DateTime.from_iso8601(a),
         {:ok, b, _} <- DateTime.from_iso8601(b) do
      DateTime.compare(a, b) == :eq
    else
      _ -> false
    end
  end

  @doc "None: every request is placed or the run is infeasible."
  @spec obligations(map()) :: [map()]
  def obligations(_assignments), do: []

  @doc "The independent check: `MobileValidator`."
  @spec validate(map(), map()) :: :ok | {:error, [AshPlanning.Violation.t()]}
  defdelegate validate(problem, assignments), to: MobileValidator

  # ── apply ──────────────────────────────────────────────────────────────────

  @doc "The day's inputs as they are now (the freshness recheck's other side)."
  @spec current_inputs(map()) :: {:ok, [AshOpenLineage.Snapshot.Input.t()]} | {:error, term()}
  def current_inputs(payload) do
    with {:ok, day, clinician_id, matrix_key} <- scope_of(payload),
         {:ok, facts} <-
           MobileReader.read(day, clinician_id, DateTime.utc_now(), matrix_key: matrix_key) do
      {:ok, MobileReader.inputs(facts)}
    end
  end

  @doc """
  Writes the candidate's route as the approving person. Each stop is one of:

    * **book** — the request is `:requested`: a mobile `Appointment` is booked at the
      planned start with the request's patient, type and location, for the planned
      veterinarian, and the request is marked scheduled (under the apply marker,
      `Checks.AppliedByCandidate`);
    * **move** — the request is scheduled and the plan starts it elsewhere: its
      appointment is rescheduled;
    * **keep** — the request is scheduled and the plan keeps its start: untouched,
      counted as preserved.

  The first refusal stops the rest and is returned as `{:error, {:refused, error}}`;
  the caller rolls everything back. A candidate or problem that cannot be read is a
  bare atom.
  """
  @spec apply_plan(struct(), map(), map()) :: {:ok, map()} | {:error, term()}
  def apply_plan(candidate, payload, actor) do
    with {:ok, stops} <- stops(candidate),
         {:ok, day, clinician_id, matrix_key} <- scope_of(payload),
         {:ok, facts} <-
           MobileReader.read(day, clinician_id, DateTime.utc_now(), matrix_key: matrix_key),
         {:ok, steps} <- steps(stops, facts) do
      transact(candidate, steps, clinician_id, actor)
    end
  end

  defp scope_of(%{"problem" => %{"day" => day, "clinician_id" => clinician_id} = problem}) do
    with {:ok, day} <- Date.from_iso8601(day),
         do: {:ok, day, clinician_id, problem["matrix_key"] || @default_matrix_key}
  end

  defp scope_of(_payload), do: {:error, :problem_unreadable}

  defp stops(candidate) do
    with binary when is_binary(binary) <- candidate.assignments,
         {:ok, %{"stops" => stops}} <- Jason.decode(binary) do
      {:ok, Enum.sort_by(stops, & &1["order"])}
    else
      _ -> {:error, :assignments_unreadable}
    end
  end

  defp steps(stops, facts) do
    by_id = Map.new(facts.visits, &{&1.id, &1})

    stops
    |> Enum.reduce_while({:ok, []}, fn stop, {:ok, acc} ->
      with %{} = visit <- by_id[stop["visit_request_id"]],
           {:ok, starts_at, _} <- DateTime.from_iso8601(stop["starts_at"]) do
        {:cont, {:ok, [step(visit, starts_at) | acc]}}
      else
        _ -> {:halt, {:error, :assignments_unreadable}}
      end
    end)
    |> case do
      {:ok, steps} -> {:ok, Enum.reverse(steps)}
      error -> error
    end
  end

  defp step(%{state: :requested} = visit, starts_at), do: {:book, visit, starts_at}

  defp step(visit, starts_at) do
    if DateTime.compare(visit.previous_starts_at, starts_at) == :eq,
      do: {:keep, visit},
      else: {:move, visit, starts_at}
  end

  defp transact(candidate, steps, clinician_id, actor) do
    opts = [actor: actor]
    schedule_ids = MapSet.new(for {:book, visit, _starts_at} <- steps, do: visit.id)

    result =
      AppliedByCandidate.with_marker(candidate.id, schedule_ids, fn ->
        run_steps(steps, clinician_id, opts)
      end)

    case result do
      :ok ->
        {:ok,
         %{
           booked_visits: Enum.count(steps, &match?({:book, _, _}, &1)),
           moved_visits: Enum.count(steps, &match?({:move, _, _}, &1)),
           preserved_visits: Enum.count(steps, &match?({:keep, _}, &1))
         }}

      {:error, error} ->
        {:error, {:refused, error}}
    end
  end

  defp run_steps(steps, clinician_id, opts) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case run_step(step, clinician_id, opts) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp run_step({:keep, _visit}, _clinician_id, _opts), do: :ok

  defp run_step({:move, visit, starts_at}, _clinician_id, opts),
    do: ok(Scheduling.reschedule_appointment(visit.appointment_id, starts_at, opts))

  defp run_step({:book, visit, starts_at}, clinician_id, opts) do
    with {:ok, appointment} <-
           Scheduling.book_appointment(
             %{
               patient_id: visit.patient_id,
               clinician_id: clinician_id,
               appointment_type_id: visit.appointment_type_id,
               scheduled_at: starts_at,
               duration_minutes: visit.booked_minutes,
               reason: visit.reason_text,
               location_mode: :mobile,
               service_location_id: visit.location_id
             },
             opts
           ) do
      ok(Scheduling.schedule_visit_request(visit.id, appointment.id, opts))
    end
  end

  defp ok({:ok, _record}), do: :ok
  defp ok({:error, error}), do: {:error, error}
end
