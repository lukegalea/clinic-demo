defmodule ClinicDemo.EvidenceSpike.Extraction do
  @moduledoc """
  What the extraction model may say about one certificate.

  The struct **is** the schema. `ash_ai` derives the JSON schema the model is
  constrained to from these field definitions, and the model's reply is cast
  back through the same definitions, with every refinement applied.

  Every field is a *proposal*, not a fact:

    * `value` — the proposed value, or `null`;
    * `status` — `found`, `not_found` or `ambiguous`. The last two are the
      abstentions: the model is never forced to invent a value;
    * `source_ids` — the atom ids the value was read from.

  There is **no confidence field**, on purpose. A generative model's
  self-reported confidence is not a probability anyone has calibrated. The
  probability comes from the verification rung instead
  (the `:verify` action on `ClinicDemo.EvidenceSpike.Extractor`).

  Some refinements cannot travel in the wire schema: `ash_ai` does not emit a
  JSON Schema `pattern` for a `match` constraint, and it does not emit string
  length bounds. Those are enforced only when Ash re-casts the reply. That is
  the point of re-casting. A reply that breaks them is rejected and recorded as
  a cast failure. Nothing repairs it.
  """

  use Ash.TypedStruct

  import ClinicDemo.EvidenceSpike.Proposal, only: [proposal: 1, proposal: 2]

  @type proposal :: %{
          value: term(),
          status: :found | :not_found | :ambiguous,
          source_ids: [String.t()]
        }

  @type t :: %__MODULE__{
          insured_name: proposal(),
          policy_number: proposal(),
          insurer: proposal(),
          coverage_type: proposal(),
          effective_date: proposal(),
          expiry_date: proposal(),
          per_claim_limit: proposal(),
          aggregate_limit: proposal()
        }

  typed_struct do
    field :insured_name, :map,
      allow_nil?: false,
      constraints: proposal(:string, max_length: 120),
      description: "The person or clinic named as the insured."

    field :policy_number, :map,
      allow_nil?: false,
      constraints: proposal(:string, match: ~r/^[A-Z]{3}-\d{7}$/),
      description: "The policy number, exactly as printed."

    field :insurer, :map,
      allow_nil?: false,
      constraints: proposal(:string, max_length: 120),
      description: "The insurance company that issued the policy."

    field :coverage_type, :map,
      allow_nil?: false,
      constraints:
        proposal(:atom, one_of: [:professional_liability, :general_liability, :not_stated]),
      description:
        "The kind of liability coverage. Use not_stated when the certificate does not say."

    field :effective_date, :map,
      allow_nil?: false,
      constraints: proposal(:date),
      description: "The first day of the policy period, as an ISO 8601 date."

    field :expiry_date, :map,
      allow_nil?: false,
      constraints: proposal(:date),
      description: "The last day of the policy period, as an ISO 8601 date."

    field :per_claim_limit, :map,
      allow_nil?: false,
      constraints: proposal(:integer, min: 0, max: 100_000_000),
      description: "The each-claim limit in Canadian dollars, as a whole number."

    field :aggregate_limit, :map,
      allow_nil?: false,
      constraints: proposal(:integer, min: 0, max: 100_000_000),
      description: "The aggregate limit in Canadian dollars, as a whole number."
  end
end
