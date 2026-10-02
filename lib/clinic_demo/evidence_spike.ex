defmodule ClinicDemo.EvidenceSpike do
  @moduledoc """
  CLIN-34: the extract-then-verify spike, on synthetic certificates only.

  The public, synthetic twin of the evidence pipeline (ADR 0044 and 0046 in
  ash_enterprise). Four rungs, each kept separate so each can be measured:

    1. **Extract.** A generative model proposes `{value, status, source_ids}`
       per field under a schema derived from an Ash type. It gets no
       confidence field. Ash re-casts the reply with every refinement.
    2. **Check.** Deterministic checks on the cast values: dates in order,
       limits consistent, citations present in the packet.
    3. **Verify.** A decision model answers one closed question per proposal
       (a Noul), via `ash_ai`'s evaluate action.
    4. **Ledger.** Each rung's output is a separate observation row.

  A spike, not a feature. Nothing else in the application depends on it. See
  `docs/research/clin-34-extract-verify.md` for the method and results.
  """

  use Ash.Domain, otp_app: :clinic_demo, validate_config_inclusion?: false

  resources do
    resource ClinicDemo.EvidenceSpike.Extractor
    resource ClinicDemo.EvidenceSpike.Observation
  end
end
