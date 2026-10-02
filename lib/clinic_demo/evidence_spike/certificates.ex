defmodule ClinicDemo.EvidenceSpike.Certificates do
  @moduledoc """
  Synthetic clinician liability-insurance certificates, each with gold values.

  Every certificate here is invented. The names, insurers, policy numbers and
  amounts are drawn from small fixed lists by a seeded generator, so the same
  `n` always produces the same packets and the same gold answers. No real
  certificate, clinic, insurer or person is represented.

  A certificate is a **packet of atoms**: short lines of text, each with an id
  (`"a01"`, `"a02"`, ...). The extractor must cite atom ids for every value it
  proposes, and the verifier is asked about one atom at a time, which keeps
  each verification well inside laya's 1,024-token context.

  The generator plants the cases a real extraction pipeline meets:

    * **missing** — a field is simply not on the certificate (gold status
      `:not_found`);
    * **ambiguous** — the certificate states two different aggregate limits
      (gold status `:ambiguous`);
    * **distractors** — atoms that look like the answer but are not (a broker's
      licence number shaped like a policy number, a "quote valid until" date).
  """

  @insureds [
    "Dr. Maren Okafor-Lindqvist",
    "Dr. Teodor Vasquez-Hale",
    "Dr. Priya Castellanos",
    "Dr. Idris Moreau-Tanaka",
    "Dr. Saoirse Bellweather",
    "Dr. Kwame Albescu",
    "Dr. Lucia Fenwick-Oyelaran",
    "Dr. Anders Quillfeather"
  ]

  @insurers [
    "Northbridge Veterinary Mutual (fictional)",
    "Maple Tier Professional Underwriters (fictional)",
    "Lakeshore Clinician Assurance (fictional)",
    "Fieldstone Liability Co-operative (fictional)"
  ]

  @coverages [
    {:professional_liability, "Professional liability (malpractice)"},
    {:general_liability, "Commercial general liability"}
  ]

  @per_claim [1_000_000, 2_000_000, 5_000_000]

  @fields [
    :insured_name,
    :policy_number,
    :insurer,
    :coverage_type,
    :effective_date,
    :expiry_date,
    :per_claim_limit,
    :aggregate_limit
  ]

  @doc "The fields every certificate is extracted into, in order."
  def fields, do: @fields

  @doc """
  Returns `n` certificates. Deterministic for a given `n` and `seed`.

  Each is a map with `:id`, `:atoms` (a list of `%{id, text}`) and `:gold` (a
  map of field to `%{status, value, source_ids}`).
  """
  def generate(n, seed \\ 34) when is_integer(n) and n > 0 do
    :rand.seed(:exsss, {seed, seed * 7, seed * 13})
    Enum.map(1..n, &certificate/1)
  end

  defp certificate(i) do
    insured = pick(@insureds)
    insurer = pick(@insurers)
    {coverage, coverage_text} = pick(@coverages)
    policy = "CLV-" <> Integer.to_string(:rand.uniform(8_999_999) + 1_000_000)
    per_claim = pick(@per_claim)
    aggregate = per_claim * pick([2, 3])
    effective = Date.add(~D[2026-01-01], :rand.uniform(300))
    expiry = Date.add(effective, 365)

    # Every fourth certificate omits the aggregate; every fifth states two.
    aggregate_case =
      cond do
        rem(i, 5) == 0 -> :ambiguous
        rem(i, 4) == 0 -> :missing
        true -> :stated
      end

    lines =
      [
        {:header, "CERTIFICATE OF LIABILITY INSURANCE (SYNTHETIC SPECIMEN #{i})"},
        {:insurer, "Insurer: #{insurer}"},
        {:insured_name, "Named insured: #{insured}"},
        {:distractor, "Broker licence no. BRK-#{:rand.uniform(8_999_999) + 1_000_000}"},
        {:policy_number, "Policy number: #{policy}"},
        {:coverage_type, "Coverage: #{coverage_text}"},
        {:dates,
         "Policy period: #{Date.to_iso8601(effective)} to #{Date.to_iso8601(expiry)}, 12:01 a.m. local time"},
        {:per_claim_limit, "Each claim limit: CAD $#{delimit(per_claim)}"}
      ] ++
        aggregate_lines(aggregate_case, aggregate) ++
        [
          {:distractor,
           "This certificate is issued as a matter of information only. Quote valid until #{Date.to_iso8601(Date.add(effective, -30))}."}
        ]

    atoms =
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {{tag, text}, n} ->
        %{id: atom_id(n), text: text, tag: tag}
      end)

    ids_for = fn tag -> for a <- atoms, a.tag == tag, do: a.id end

    gold = %{
      insured_name: found(insured, ids_for.(:insured_name)),
      policy_number: found(policy, ids_for.(:policy_number)),
      insurer: found(insurer, ids_for.(:insurer)),
      coverage_type: found(coverage, ids_for.(:coverage_type)),
      effective_date: found(effective, ids_for.(:dates)),
      expiry_date: found(expiry, ids_for.(:dates)),
      per_claim_limit: found(per_claim, ids_for.(:per_claim_limit)),
      aggregate_limit: aggregate_gold(aggregate_case, aggregate, ids_for.(:aggregate_limit))
    }

    %{
      id: "cert-#{String.pad_leading(Integer.to_string(i), 3, "0")}",
      atoms: Enum.map(atoms, &Map.delete(&1, :tag)),
      gold: gold
    }
  end

  defp aggregate_lines(:stated, aggregate),
    do: [{:aggregate_limit, "Aggregate limit: CAD $#{delimit(aggregate)}"}]

  defp aggregate_lines(:missing, _aggregate), do: []

  defp aggregate_lines(:ambiguous, aggregate),
    do: [
      {:aggregate_limit, "Aggregate limit: CAD $#{delimit(aggregate)}"},
      {:aggregate_limit,
       "Endorsement 3 amends the aggregate limit to CAD $#{delimit(aggregate * 2)}"}
    ]

  defp aggregate_gold(:stated, aggregate, ids), do: found(aggregate, ids)

  defp aggregate_gold(:missing, _aggregate, _ids),
    do: %{status: :not_found, value: nil, source_ids: []}

  defp aggregate_gold(:ambiguous, _aggregate, ids),
    do: %{status: :ambiguous, value: nil, source_ids: ids}

  defp found(value, ids), do: %{status: :found, value: value, source_ids: ids}

  defp atom_id(n), do: "a" <> String.pad_leading(Integer.to_string(n), 2, "0")

  defp pick(list), do: Enum.at(list, :rand.uniform(length(list)) - 1)

  defp delimit(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end
end
