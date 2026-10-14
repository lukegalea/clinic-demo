defmodule ClinicDemo.Scheduling.Calculations.AcuityFact do
  @moduledoc """
  The appointment row's judgment badge: the patient's admitted acuity FACT,
  read through `AshJudgments.Query.status/4` over the facts table (P4-S5) —
  never re-derived from the visit, and never folded into the
  `triage_urgency` scheduling attribute beside it on the card. The attribute
  is what the visit wrote; this badge is what the judgment record admits.

  Three-valued, per the package's membership law (unknown is never folded
  into either side):

    * the admitted urgency (`{:in, fact}` — the fact holds, so the badge
      reads the fact's own value: "urgent", "soon", …);
    * `"ruled out"` (`{:out, _fact}` — an admitted fact says the acuity
      predicate does not hold; the triage path never writes this shape,
      a person verdict or refusal does);
    * `"no fact"` (`{:unknown, reason}` — nothing admitted: never judged,
      an omitted judgment, expired, or below the consumer's grade floor).

  Batched per page like `ComplianceStatus`: one `Query.status/4` read per
  DISTINCT patient on the page (visits of the same patient share the fact —
  the fact is about the animal), deduplicated before the reads.

  Staleness note, on the record: the facts table carries each admitted
  fact's `subject_state_digest`, and `Query.status/4` marks a fact stale —
  `{:unknown, :stale}` — only against a `:current_digests` timeline the
  host keeps per §7.4. This demo does not keep digest periods (that is the
  C2 capability, proven in vpm_poc), so the badge reads admitted facts
  as-of now without a staleness opinion. The as-of variant that the
  standings reads use is `ClinicDemo.Judgments.Standings.status_at/4`.
  """

  use Ash.Resource.Calculation

  alias ClinicDemo.Judgments.Fact
  alias ClinicDemo.Judgments.Triage

  @ruled_out "ruled out"
  @no_fact "no fact"

  @doc "The `{:out, _}` rendering — an admitted fact denies the predicate."
  def ruled_out, do: @ruled_out

  @doc "The `{:unknown, _}` rendering — the judgment record has nothing to say."
  def no_fact, do: @no_fact

  @impl true
  def calculate(records, _opts, _context) do
    verdicts =
      records
      |> Enum.map(& &1.patient_id)
      |> Enum.uniq()
      |> Map.new(fn patient_id ->
        {patient_id, verdict(patient_id)}
      end)

    Enum.map(records, &Map.fetch!(verdicts, &1.patient_id))
  end

  # One facts read per distinct patient: the package's per-subject tri-state
  # entry, rendered into the surface vocabulary.
  defp verdict(patient_id) do
    AshJudgments.Query.status(Fact, Triage.subject(patient_id), Triage.question_id())
    |> case do
      {:in, fact} -> to_string(fact.value)
      {:out, _fact} -> @ruled_out
      {:unknown, _reason} -> @no_fact
    end
  end
end
