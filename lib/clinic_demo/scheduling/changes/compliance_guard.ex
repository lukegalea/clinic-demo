defmodule ClinicDemo.Scheduling.Changes.ComplianceGuard do
  @moduledoc """
  Guards an appointment transition against the active compliance rule bundle.

  Synchronous, and deliberately so: a transition that violates an active rule
  does not happen, rather than happening and being reported. The fired rules'
  gap texts become the action's error, so the refusal a caller reads is the
  operator's own wording, filed under the rule id that produced it.

  Three properties worth naming:

  **It is inert until a bundle is activated.** A fresh database has no active
  policy bundle, and the guard steps aside rather than pretending one exists —
  the demo boots pre-seed and the rules arrive when `mix seed` activates them.

  **It fails closed.** A bundle that cannot be decoded or evaluated refuses
  the transition instead of skipping the check: the one state a compliance
  guard may never occupy is "the rules were unreadable, so proceed".

  **The evaluation record never vetoes the decision.** The audit row is
  written after the transaction, best-effort; a failure to file the audit
  logs a warning rather than failing a transition that legitimately passed.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias ClinicDemo.Compliance

  require Logger

  @impl true
  def change(changeset, opts, _context) do
    transition_to = Keyword.fetch!(opts, :transition_to)

    case active_bundle() do
      # Pre-seed state: no rules in force, nothing to guard against.
      {:ok, nil} ->
        changeset

      {:ok, bundle} ->
        guard(changeset, bundle, transition_to)

      {:error, reason} ->
        refuse(changeset, "the active policy bundle could not be read: #{inspect(reason)}")
    end
  end

  # --- evaluation ---------------------------------------------------------------

  defp guard(changeset, bundle, transition_to) do
    facts = facts(changeset, transition_to)

    with {:ok, ir} <- AshRules.Ir.decode(bundle.rules_json),
         {:ok, result} <- AshRules.evaluate(ir, facts) do
      settle(changeset, result, bundle, facts)
    else
      {:error, reason} ->
        refuse(changeset, "the active policy bundle could not be evaluated: #{inspect(reason)}")
    end
  end

  defp settle(changeset, result, bundle, facts) do
    case result.overall do
      overall when overall in [:noncompliant, :unknown, :error] ->
        refuse(changeset, refusal_message(AshRules.Result.findings(result), overall))

      _compliant ->
        record_decision(changeset, result, bundle, facts)
    end
  end

  # The gap text is the operator's own wording; the rule id is what makes the
  # refusal traceable back to the bundle row that produced it.
  defp refusal_message([_ | _] = findings, _overall) do
    findings
    |> Enum.map_join("; ", fn finding -> "#{finding.gap} (#{finding.rule_id})" end)
    |> then(&"compliance: #{&1}")
  end

  # No rule fired but the engine still could not permit — only reachable if a
  # future fact schema declares `missing: :unknown` predicates. Refuse anyway.
  defp refusal_message([], overall) do
    "compliance: the rules could not decide this transition (outcome: #{inspect(overall)})"
  end

  defp refuse(changeset, message) do
    Ash.Changeset.add_error(
      changeset,
      InvalidAttribute.exception(field: :compliance, message: message)
    )
  end

  # --- facts ----------------------------------------------------------------------

  # The subject is the string "appointment", deliberately not the atom: a
  # bundle's predicates travel through the compliance control plane as JSON,
  # and subject terms are opaque there — the DSL's `has(:appointment, ...)`
  # arrives back as "appointment". Facts are emitted under the post-compile
  # spelling so the probes always meet the rules.
  @subject "appointment"

  # Plain triples over that subject, precomputed here so the rule bundle
  # speaks clinic policy rather than appointment storage.
  defp facts(changeset, transition_to) do
    data = changeset.data

    [
      {@subject, :transition_to, transition_to},
      {@subject, :patient_weight_recorded, weight_recorded?(data)},
      {@subject, :has_triage_urgency, not is_nil(data.triage_urgency)},
      {@subject, :has_notes, notes_present?(changeset, data)}
    ]
  end

  defp weight_recorded?(data) do
    case Ash.load(data, :patient, authorize?: false) do
      {:ok, %{patient: %{weight_kg: weight}}} when not is_nil(weight) -> true
      _ -> false
    end
  end

  # :complete carries notes as an argument; the attribute is only set later in
  # the same action, so the argument is the truth and the attribute the fallback.
  defp notes_present?(changeset, data) do
    case Ash.Changeset.get_argument(changeset, :notes) || data.notes do
      nil -> false
      "" -> false
      _notes -> true
    end
  end

  # --- the audit trail --------------------------------------------------------------

  defp record_decision(changeset, result, bundle, facts) do
    Ash.Changeset.after_action(changeset, fn changeset, appointment ->
      record_evaluation(changeset, result, bundle, facts, appointment)
      {:ok, appointment}
    end)
  end

  # Best effort by design: see the moduledoc. `rescue` rather than a case on
  # {:error, _} because the bang interface raises and a database hiccup raises
  # too — both are "the audit row did not land", which is a warning, not a veto.
  defp record_evaluation(changeset, result, bundle, facts, appointment) do
    AshCompliance.Domain.record_evaluation!(
      %{
        organization_id: Compliance.organization_id(),
        subject_type: "appointment",
        subject_id: appointment.id,
        bundle_hash: result.bundle_hash,
        bundle_revision: result.bundle_revision,
        evaluator: inspect(result.evaluator),
        compiler_version: bundle.compiler_version,
        outcome: result.overall,
        fact_snapshot_hash: fact_snapshot_hash(facts),
        missing_facts: Enum.map(result.missing_facts, &format_triple/1),
        rule_ids: applicable_rule_ids(result),
        correlation_id: Ash.UUID.generate(),
        source_event_id: actor_id(changeset),
        evaluated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      authorize?: false
    )
  rescue
    error ->
      Logger.warning(
        "compliance evaluation for appointment #{appointment.id} was not recorded: " <>
          Exception.message(error)
      )
  end

  defp fact_snapshot_hash(facts) do
    facts
    |> Enum.sort()
    |> inspect()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp applicable_rule_ids(result) do
    Enum.flat_map(result.requirements, fn
      %{outcome: :not_applicable} -> []
      %{rule_id: rule_id} -> [rule_id]
    end)
  end

  defp format_triple({subject, predicate, value}),
    do: "#{subject}/#{predicate}/#{inspect(value)}"

  defp actor_id(%{context: %{private: %{actor: %{id: id}}}}), do: to_string(id)
  defp actor_id(_), do: nil

  defp active_bundle do
    AshCompliance.Domain.active_policy_bundle(Compliance.organization_id(), authorize?: false)
  end
end
