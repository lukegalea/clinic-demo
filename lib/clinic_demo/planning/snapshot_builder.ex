defmodule ClinicDemo.Planning.SnapshotBuilder do
  @moduledoc """
  Prepares a `:pending` `ClinicDemo.Planning.Run`: has the run's model
  (`ClinicDemo.Planning.Model`) read its declared inputs and lower them to the
  model's data, seals the references-and-hashes envelope (`AshOpenLineage.Snapshot`)
  and records the result on the run's *preparation* axis.

      SnapshotBuilder.prepare(run, week_start: ~D[2026-11-09]) :: {:ok, %Run{}} | {:error, term}
      SnapshotBuilder.prepare(run, day: ~D[2026-11-10], clinician_id: id) :: {:ok, %Run{}}

  The options are the model's (`week_start` for the roster; `day`, `clinician_id` and
  `matrix_key` for mobile visits) plus `:cutoff` and `:completeness`. The model is
  the one the run's pinned `ModelVersion` is a version of.

  A run that is not `:pending` is returned unchanged, so a retried job is
  idempotent. The write is `Run.prepare` as the planner (`Machinery`), the only
  way the axis moves.

  ## What is read

  What the model declares, **`as_of` the run's knowledge cutoff** for every temporal
  resource. For the roster, `ClinicDemo.Planning.Reader` reads the week's scheduled
  appointments and availability plus the active clinicians, shift templates and
  applied shifts and assignments, and `ClinicDemo.Planning.StaffingPolicy`
  evaluates `staffing.policy` at the version and hash the run's binding pinned. For
  mobile visits, `ClinicDemo.Planning.MobileReader` reads the day's visit requests,
  the vet's calendar and the pinned travel matrix. The binding is read `as_of` the
  cutoff too.

  ## What is recorded

  Per input: `(resource, id, version_number)` as `source` and a `content_hash`;
  per definition: kind, key, version and content hash (the binding's selection,
  which must agree with the model version's own hashes). The envelope with its
  digest rides inside the problem payload under `"snapshot"`: references and
  hashes only, never values. `Run.snapshot_digest` is that digest.

  ## Outcomes

    * `:prepared` — every input is a `:value`.
    * `:needs_input` — at least one input is not (an appointment that cannot be
      planned as it stands; a mobile visit whose travel is unknown): `unresolved_inputs`
      names each by id with a reason code, the digest is recorded and nothing is
      solved. Never a silent default.
    * `:preparation_failed` — the binding, model version, decision or a read could
      not be resolved; the reason code is in `stats["reason"]`.
  """

  alias AshOpenLineage.Snapshot
  alias AshOpenLineage.Snapshot.{Definition, Input}
  alias AshPlanning.Snapshot, as: PlanningSnapshot
  alias ClinicDemo.Planning
  alias ClinicDemo.Planning.{Machinery, Model, ModelVersion, Reader, Run}

  @roles %{
    "appointment" => :appointment,
    "availability" => :availability,
    "clinician" => :clinician,
    "template" => :template,
    "applied_shift" => :applied_shift,
    "applied_assignment" => :applied_assignment,
    "visit_request" => :visit_request,
    "service_location" => :service_location,
    "travel_matrix" => :travel_matrix
  }
  @statuses %{
    "value" => :value,
    "unresolved" => :unresolved,
    "invalid" => :invalid,
    "missing_citation" => :missing_citation
  }
  @worlds %{"operational" => :operational, "scenario" => :scenario}
  @completeness %{
    "authorized_subset" => :authorized_subset,
    "declared_complete" => :declared_complete
  }
  @kinds %{"dmn" => :dmn, "bpmn" => :bpmn, "mzn" => :mzn, "validator" => :validator}

  @doc """
  Prepares a pending run. The options are the run's model's (`:week_start` for the
  roster, a Monday; `:day` and `:clinician_id` for mobile visits) plus `:cutoff`
  (the knowledge cutoff, default now) and `:completeness` (the run's declared scope).
  """
  @spec prepare(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def prepare(run, opts \\ [])

  def prepare(%Run{preparation_status: :pending} = run, opts) do
    cutoff = run.knowledge_cutoff || Keyword.get(opts, :cutoff) || DateTime.utc_now()
    completeness = Keyword.get(opts, :completeness, :authorized_subset)

    case model_of(run) do
      {:ok, model, version} ->
        run
        |> build(model, version, opts, cutoff, completeness)
        |> record(run, cutoff, model.scope(opts))

      {:error, reason} ->
        record({:failed, reason}, run, cutoff, %{})
    end
  end

  def prepare(%Run{} = run, _opts), do: {:ok, run}

  @doc """
  The snapshot envelope stored in a prepared run's decoded problem payload,
  rebuilt as a `AshOpenLineage.Snapshot` with its digest *verified*.
  """
  @spec snapshot_from_payload(map()) :: {:ok, Snapshot.t()} | {:error, term()}
  def snapshot_from_payload(%{"snapshot" => %{} = map}) do
    with {:ok, snapshot} <- decode_snapshot(map) do
      if PlanningSnapshot.verify(snapshot),
        do: {:ok, snapshot},
        else: {:error, :snapshot_digest_mismatch}
    end
  end

  def snapshot_from_payload(_payload), do: {:error, :no_snapshot}

  @doc "The run's decoded problem payload."
  @spec problem_payload(struct()) :: {:ok, map()} | {:error, term()}
  def problem_payload(%Run{problem_payload: payload}) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, :problem_payload_unreadable}
    end
  end

  def problem_payload(%Run{}), do: {:error, :empty}

  @doc """
  The planning model a run is for: the module declared under its pinned model
  version's key, and the version.
  """
  @spec model_of(struct()) :: {:ok, module(), struct()} | {:error, atom()}
  def model_of(%Run{model_version_id: id}) do
    with {:ok, version} <- Ash.get(ModelVersion, id, authorize?: false),
         {:ok, model} <- Model.for_key(version.key) do
      {:ok, model, version}
    else
      _ -> {:error, :model_version_unavailable}
    end
  end

  # ── build ──────────────────────────────────────────────────────────────────

  defp build(run, model, version, opts, cutoff, completeness) do
    stamped = %{run | knowledge_cutoff: cutoff}

    with {:ok, binding} <- fetch(Run.resolve_binding(stamped), :binding_unavailable),
         {:ok, definitions} <- definitions(binding, version),
         {:ok, built} <- model.build(run, opts, cutoff, definitions) do
      assemble(run, model, cutoff, built, definitions, completeness)
    else
      {:error, reason} -> {:failed, reason}
    end
  end

  defp assemble(run, model, cutoff, built, definitions, completeness) do
    unresolved = Enum.filter(built.inputs, &(&1.status != :value))
    stats = Map.put(built.stats, "inputs", length(built.inputs))

    base = %Snapshot{
      id: run.id,
      purpose: model.definition().purpose_atom,
      effective_at: built.effective_at,
      knowledge_cutoff: cutoff,
      world: run.world,
      authority: %{tenant: nil, actor_id: run.requested_actor_id, completeness: completeness},
      inputs: built.inputs,
      definitions: definitions
    }

    cond do
      unresolved != [] ->
        {:needs_input, PlanningSnapshot.seal(base),
         Enum.map(unresolved, &unresolved_entry(&1, built.reasons)), stats}

      is_nil(built.body) ->
        {:failed, :nothing_lowered}

      true ->
        snapshot = PlanningSnapshot.seal(%{base | payload_hash: Reader.hash(built.body)})
        payload = Map.put(built.body, "snapshot", encode_snapshot(snapshot))
        {:prepared, snapshot, payload, stats}
    end
  end

  defp unresolved_entry(%Input{} = input, reasons) do
    %{
      "id" => input.key,
      "resource" => input.source && to_string(input.source.resource),
      "status" => Atom.to_string(input.status),
      "reason" => Map.get(reasons, input.key, Atom.to_string(input.status))
    }
  end

  # ── record ─────────────────────────────────────────────────────────────────

  defp record({:prepared, snapshot, payload, stats}, run, cutoff, _scope) do
    write(run, %{
      preparation_status: :prepared,
      snapshot_digest: snapshot.digest,
      knowledge_cutoff: cutoff,
      problem_payload: Jason.encode!(payload),
      stats: stats
    })
  end

  defp record({:needs_input, snapshot, unresolved, stats}, run, cutoff, _scope) do
    write(run, %{
      preparation_status: :needs_input,
      snapshot_digest: snapshot.digest,
      knowledge_cutoff: cutoff,
      unresolved_inputs: unresolved,
      stats: stats
    })
  end

  defp record({:failed, reason}, run, cutoff, scope) do
    write(run, %{
      preparation_status: :preparation_failed,
      knowledge_cutoff: cutoff,
      stats: Map.put(scope, "reason", reason_string(reason))
    })
  end

  defp write(run, params), do: Planning.prepare_run(run, params, actor: Machinery.actor())

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(_other), do: "unknown"

  # ── binding / definitions ──────────────────────────────────────────────────

  defp fetch({:ok, value}, _reason), do: {:ok, value}
  defp fetch({:error, _}, reason), do: {:error, reason}

  # The binding's selection is what the run is pinned to. It must agree with the
  # model version's own hashes: a binding reviewed against another model or
  # checker is `definition_drift`, not a plan.
  defp definitions(binding, mv) do
    selected =
      for entry <- binding.selection || [],
          kind = Map.get(@kinds, to_string(get(entry, :kind))),
          not is_nil(kind) do
        %Definition{
          kind: kind,
          key: to_string(get(entry, :key)),
          version: to_string(get(entry, :version)),
          content_hash: to_string(get(entry, :content_hash))
        }
      end

    expected = [
      {:mzn, mv.key, mv.model_sha256},
      {:mzn, mv.key <> ".checker", mv.checker_sha256},
      {:validator, mv.validator_module, mv.validator_sha256}
    ]

    agrees? =
      Enum.all?(expected, fn {kind, key, hash} ->
        Enum.any?(selected, &(&1.kind == kind and &1.key == key and &1.content_hash == hash))
      end)

    if agrees?, do: {:ok, selected}, else: {:error, :definition_drift}
  end

  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  # ── envelope <-> JSON ──────────────────────────────────────────────────────

  defp encode_snapshot(%Snapshot{} = s) do
    %{
      "id" => s.id,
      "purpose" => Atom.to_string(s.purpose),
      "effective_at" => DateTime.to_iso8601(s.effective_at),
      "knowledge_cutoff" => DateTime.to_iso8601(s.knowledge_cutoff),
      "world" => Atom.to_string(s.world),
      "authority" => %{
        "tenant" => s.authority.tenant,
        "actor_id" => s.authority.actor_id,
        "completeness" => Atom.to_string(s.authority.completeness)
      },
      "inputs" =>
        Enum.map(s.inputs, fn i ->
          %{
            "key" => i.key,
            "role" => Atom.to_string(i.role),
            "status" => Atom.to_string(i.status),
            "source" =>
              i.source &&
                %{
                  "resource" => to_string(i.source.resource),
                  "id" => i.source.id,
                  "version_number" => i.source.version_number
                },
            "content_hash" => i.content_hash
          }
        end),
      "definitions" =>
        Enum.map(s.definitions, fn d ->
          %{
            "kind" => Atom.to_string(d.kind),
            "key" => d.key,
            "version" => d.version,
            "content_hash" => d.content_hash
          }
        end),
      "payload_hash" => s.payload_hash,
      "digest" => s.digest
    }
  end

  defp decode_snapshot(map) do
    with {:ok, purpose} <- purpose_from(map["purpose"]),
         {:ok, world} <- Map.fetch(@worlds, map["world"]),
         {:ok, completeness} <-
           Map.fetch(@completeness, get_in(map, ["authority", "completeness"])),
         {:ok, effective_at, _} <- DateTime.from_iso8601(map["effective_at"]),
         {:ok, cutoff, _} <- DateTime.from_iso8601(map["knowledge_cutoff"]),
         {:ok, inputs} <- decode_list(map["inputs"], &decode_input/1),
         {:ok, definitions} <- decode_list(map["definitions"], &decode_definition/1) do
      {:ok,
       %Snapshot{
         id: map["id"],
         purpose: purpose,
         effective_at: effective_at,
         knowledge_cutoff: cutoff,
         world: world,
         authority: %{
           tenant: get_in(map, ["authority", "tenant"]),
           actor_id: get_in(map, ["authority", "actor_id"]),
           completeness: completeness
         },
         inputs: inputs,
         definitions: definitions,
         payload_hash: map["payload_hash"],
         digest: map["digest"]
       }}
    else
      _ -> {:error, :snapshot_unreadable}
    end
  end

  defp purpose_from(name) when is_binary(name) do
    case Enum.find(Model.purposes(), &(Atom.to_string(&1) == name)) do
      nil -> :error
      purpose -> {:ok, purpose}
    end
  end

  defp purpose_from(_other), do: :error

  defp decode_list(list, fun) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp decode_list(_other, _fun), do: :error

  defp decode_input(%{} = i) do
    with {:ok, role} <- Map.fetch(@roles, i["role"]),
         {:ok, status} <- Map.fetch(@statuses, i["status"]) do
      source =
        case i["source"] do
          %{"resource" => r, "id" => id, "version_number" => v} ->
            %{resource: r, id: id, version_number: v}

          _ ->
            nil
        end

      {:ok,
       %Input{
         key: i["key"],
         role: role,
         status: status,
         source: source,
         content_hash: i["content_hash"]
       }}
    else
      _ -> :error
    end
  end

  defp decode_input(_), do: :error

  defp decode_definition(%{} = d) do
    case Map.fetch(@kinds, d["kind"]) do
      {:ok, kind} ->
        {:ok,
         %Definition{
           kind: kind,
           key: d["key"],
           version: d["version"],
           content_hash: d["content_hash"]
         }}

      :error ->
        :error
    end
  end

  defp decode_definition(_), do: :error
end
