defmodule ClinicDemo.EvidenceSpike.Runner do
  @moduledoc """
  Runs the spike over N synthetic certificates and summarises the ledger.

  For each certificate and each extraction path (`:static` through the prompt
  action; `:enum` through the host-code path), it:

    1. extracts, and records an `:extraction` row with the raw reply, the
       schema hash, the model label, the provenance and whether the cast held;
    2. records a `:proposal` row per field;
    3. runs the deterministic checks, and records a `:check` row each;
    4. asks each verifier one Noul per found proposal that cites at least one
       atom in the packet, and records a `:verification` row each.

  `summarize/2` computes the metrics the ticket names from the ledger rows,
  not from in-memory results. That way the ledger is what gets measured.
  """

  alias ClinicDemo.EvidenceSpike.{Certificates, Extractor, Models, Observation, Wire}

  @event [:clinic_demo, :evidence_spike, :wire]

  @coverage_text %{
    professional_liability: "professional liability",
    general_liability: "commercial general liability",
    not_stated: "not stated"
  }

  @doc """
  Runs the spike. Options: `:n` (default 20), `:paths` (default
  `[:static, :enum]`), `:verifiers` (default laya and winnow:e4b).

  Returns `{summary, certificates}`.
  """
  def run(opts \\ []) do
    n = Keyword.get(opts, :n, 20)
    paths = Keyword.get(opts, :paths, [:static, :enum])
    verifiers = Keyword.get(opts, :verifiers, ["laya:typed-decisions", "winnow:e4b"])
    certificates = Certificates.generate(n)
    run_id = "run-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, @event, &__MODULE__.forward_wire/4, self())

    try do
      for cert <- certificates, path <- paths, do: run_one(run_id, cert, path, verifiers)
    after
      :telemetry.detach(handler)
    end

    rows = Observation.list!(query: [filter: [run_id: run_id]])
    {Map.put(summarize(certificates, rows), :run_id, run_id), certificates}
  end

  @doc false
  def forward_wire(_event, measurements, metadata, pid),
    do: send(pid, {:wire, measurements, metadata})

  defp run_one(run_id, cert, path, verifiers) do
    flush_wire()
    ids = Enum.map(cert.atoms, & &1.id)

    {result, schema} =
      case path do
        :static -> {Extractor.extract(cert.atoms), Extractor.static_schema()}
        :enum -> {Extractor.extract_with_enum(cert.atoms, ids), Extractor.enum_schema(ids)}
      end

    wire = take_wire()

    Observation.record!(%{
      kind: :extraction,
      run_id: run_id,
      certificate_id: cert.id,
      path: path,
      raw_reply: wire[:object] && %{"reply" => wire[:object]},
      schema_hash: Wire.schema_hash(schema),
      model: wire[:model],
      provenance: wire[:provenance],
      latency_ms: wire[:latency_ms],
      output_tokens: output_tokens(wire[:usage]),
      passed: match?({:ok, _}, result),
      detail: error_text(result)
    })

    case result do
      {:ok, extraction} ->
        proposals = Map.new(Certificates.fields(), &{&1, Map.fetch!(extraction, &1)})
        record_proposals(run_id, cert, path, proposals, wire)
        record_checks(run_id, cert, path, proposals, ids)
        record_verifications(run_id, cert, path, proposals, ids, verifiers)

      {:error, _} ->
        :ok
    end
  end

  defp record_proposals(run_id, cert, path, proposals, wire) do
    for {field, p} <- proposals do
      Observation.record!(%{
        kind: :proposal,
        run_id: run_id,
        certificate_id: cert.id,
        path: path,
        field: field,
        value: render(field, p.value),
        status: p.status,
        source_ids: p.source_ids,
        passed: correct?(p, cert.gold[field]),
        model: wire[:model],
        provenance: wire[:provenance]
      })
    end
  end

  defp record_checks(run_id, cert, path, proposals, ids) do
    for {name, passed, detail} <- checks(proposals, ids) do
      Observation.record!(%{
        kind: :check,
        run_id: run_id,
        certificate_id: cert.id,
        path: path,
        field: name,
        passed: passed,
        detail: detail
      })
    end
  end

  @doc """
  The declaration rung: deterministic checks on cast proposals.

  Returns `[{check, passed?, detail}]`. A check whose inputs were not found
  passes vacuously and says so.
  """
  def checks(proposals, ids) do
    eff = found_value(proposals[:effective_date])
    exp = found_value(proposals[:expiry_date])
    per = found_value(proposals[:per_claim_limit])
    agg = found_value(proposals[:aggregate_limit])

    fabricated =
      for {field, p} <- proposals, id <- p.source_ids, id not in ids, do: "#{field}:#{id}"

    uncited = for {field, p} <- proposals, p.status == :found, p.source_ids == [], do: field

    [
      if(eff && exp,
        do: {:dates_ordered, Date.compare(eff, exp) == :lt, "#{eff} < #{exp}"},
        else: {:dates_ordered, true, "vacuous: a date was not found"}
      ),
      if(per && agg,
        do: {:limits_consistent, agg >= per, "aggregate #{agg} >= each claim #{per}"},
        else: {:limits_consistent, true, "vacuous: a limit was not found"}
      ),
      {:citations_in_packet, fabricated == [], Enum.join(fabricated, ", ")},
      {:found_is_cited, uncited == [], Enum.join(uncited, ", ")}
    ]
  end

  defp record_verifications(run_id, cert, path, proposals, ids, verifiers) do
    atoms = Map.new(cert.atoms, &{&1.id, &1.text})

    for {field, p} <- proposals, p.status == :found, not is_nil(p.value) do
      cited = Map.take(atoms, Enum.filter(p.source_ids, &(&1 in ids)))
      rendered = render(field, p.value)

      for verifier <- verifiers do
        base = %{
          kind: :verification,
          run_id: run_id,
          certificate_id: cert.id,
          path: path,
          field: field,
          value: rendered,
          source_ids: Map.keys(cited),
          passed: correct?(p, cert.gold[field])
        }

        Observation.record!(Map.merge(base, verification(verifier, cited, field, rendered)))
      end
    end
  end

  # No cited atom in the packet (every citation was fabricated): there is
  # nothing to put to a verifier, so the row records that instead of a call.
  defp verification(verifier, cited, _field, _rendered) when cited == %{} do
    %{model: Wire.model_label(Models.verifier(verifier)), detail: "no cited atom in packet"}
  end

  defp verification(verifier, cited, field, rendered) do
    flush_wire()
    result = Extractor.verify(verifier, cited, field, rendered)
    wire = take_wire()

    %{
      probability: ok_probability(result),
      model: wire[:model] || Wire.model_label(Models.verifier(verifier)),
      provenance: wire[:provenance],
      latency_ms: wire[:latency_ms],
      raw_reply: wire[:object] && %{"reply" => wire[:object]},
      detail: error_text(result)
    }
  end

  @doc """
  The metrics, computed from ledger rows.
  """
  def summarize(certificates, rows) do
    by_path = Enum.group_by(rows, & &1.path)

    %{
      certificates: length(certificates),
      provenance: rows |> Enum.map(& &1.provenance) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      paths:
        Map.new(by_path, fn {path, rows} -> {path, path_metrics(rows, length(certificates))} end)
    }
  end

  defp path_metrics(rows, n) do
    kinds = Enum.group_by(rows, & &1.kind)
    extractions = kinds[:extraction] || []
    proposals = kinds[:proposal] || []
    checks = kinds[:check] || []
    verifications = kinds[:verification] || []
    cited = Enum.filter(proposals, &(&1.source_ids != []))

    fabricated =
      Enum.count(checks, &(&1.field == :citations_in_packet and not &1.passed))

    fields = length(Certificates.fields())

    %{
      extractions: length(extractions),
      cast_failures: Enum.count(extractions, &(not &1.passed)),
      cast_failure_rate: rate(Enum.count(extractions, &(not &1.passed)), length(extractions)),
      exact_match_of_cast: rate(Enum.count(proposals, & &1.passed), length(proposals)),
      exact_match_of_all_fields: rate(Enum.count(proposals, & &1.passed), n * fields),
      exact_match_by_field:
        proposals
        |> Enum.group_by(& &1.field)
        |> Map.new(fn {f, ps} -> {f, rate(Enum.count(ps, & &1.passed), length(ps))} end),
      extractions_with_fabricated_citation: fabricated,
      fabricated_citation_rate:
        rate(fabricated, length(extractions) - Enum.count(extractions, &(not &1.passed))),
      proposals_citing: length(cited),
      checks_failed:
        checks
        |> Enum.reject(& &1.passed)
        |> Enum.frequencies_by(& &1.field),
      latency_ms: %{extract_median: median(Enum.map(extractions, & &1.latency_ms))},
      extract_output_tokens_per_s_median: median(Enum.map(extractions, &tokens_per_s/1)),
      verifiers:
        verifications
        |> Enum.group_by(& &1.model)
        |> Map.new(fn {model, vs} -> {model, verifier_metrics(vs)} end)
    }
  end

  defp verifier_metrics(vs) do
    answered = Enum.filter(vs, &is_float(&1.probability))

    agree =
      Enum.count(answered, fn v -> v.probability >= 0.5 == v.passed end)

    %{
      asked: length(vs),
      answered: length(answered),
      unanswerable: Enum.count(vs, &(&1.detail == "no cited atom in packet")),
      agreement_at_0_5: rate(agree, length(answered)),
      mean_p_when_correct: mean(for v <- answered, v.passed, do: v.probability),
      mean_p_when_wrong: mean(for v <- answered, not v.passed, do: v.probability),
      wrong_proposals_flagged: Enum.count(answered, &(not &1.passed and &1.probability < 0.5)),
      wrong_proposals: Enum.count(answered, &(not &1.passed)),
      latency_ms_median: median(Enum.map(answered, & &1.latency_ms))
    }
  end

  @doc "Whether a proposal matches its gold value (status, and value when found)."
  def correct?(%{status: :found} = p, %{status: :found, value: gold}), do: p.value == gold
  def correct?(%{status: status}, %{status: status}), do: true
  def correct?(_proposal, _gold), do: false

  @doc "A value as it is put to a verifier and stored on a row."
  def render(_field, nil), do: nil
  def render(:coverage_type, value), do: Map.get(@coverage_text, value, to_string(value))
  def render(_field, %Date{} = d), do: Date.to_iso8601(d)

  def render(field, n) when field in [:per_claim_limit, :aggregate_limit] and is_integer(n) do
    digits =
      n
      |> Integer.to_string()
      |> String.reverse()
      |> String.to_charlist()
      |> Enum.chunk_every(3)
      |> Enum.join(",")
      |> String.reverse()

    "CAD $" <> digits
  end

  def render(_field, value), do: to_string(value)

  defp output_tokens(%{} = usage),
    do: usage["output_tokens"] || usage["completion_tokens"] || usage[:output_tokens]

  defp output_tokens(_), do: nil

  defp tokens_per_s(%{output_tokens: t, latency_ms: ms})
       when is_integer(t) and is_integer(ms) and ms > 0,
       do: Float.round(t * 1000 / ms, 1)

  defp tokens_per_s(_), do: nil

  defp found_value(%{status: :found, value: v}) when not is_nil(v), do: v
  defp found_value(_), do: nil

  defp ok_probability({:ok, %{probability: p}}) when is_number(p), do: p / 1
  defp ok_probability(_), do: nil

  defp error_text({:ok, _}), do: nil
  defp error_text({:error, error}) when is_binary(error), do: error
  defp error_text({:error, error}) when is_exception(error), do: Exception.message(error)
  defp error_text({:error, error}), do: inspect(error)

  defp flush_wire do
    receive do
      {:wire, _, _} -> flush_wire()
    after
      0 -> :ok
    end
  end

  defp take_wire do
    receive do
      {:wire, measurements, metadata} -> Map.merge(metadata, measurements)
    after
      0 -> %{}
    end
  end

  defp rate(_num, 0), do: nil
  defp rate(num, den), do: Float.round(num / den, 4)

  defp mean([]), do: nil
  defp mean(xs), do: Float.round(Enum.sum(xs) / length(xs), 4)

  defp median(xs) do
    case xs |> Enum.reject(&is_nil/1) |> Enum.sort() do
      [] -> nil
      sorted -> Enum.at(sorted, div(length(sorted), 2))
    end
  end
end
