defmodule ClinicDemo.EvidenceSpike.Observation do
  @moduledoc """
  One ledger-shaped row: something a rung of the spike observed.

  Kept in ETS, because this is a spike's dev table rather than a schema anyone
  should migrate. The shape follows the judgment-record direction in
  ADR 0046: the model's answer is **input** to a create action, never
  re-derived, so replaying the ledger never re-queries a model.

  Kinds:

    * `:extraction`: one per certificate per path. Holds the raw reply, the
      hash of the wire schema, the model label and whether the cast succeeded.
    * `:proposal`: one per field of a successful extraction.
    * `:check`: one per deterministic check.
    * `:verification`: one per proposal per verifier. Holds the Noul
      probability.

  `provenance` is `"recorded"` for a live or replayed live exchange, and
  `"stub"` for the synthetic stub. A stub row is never evidence about a model.
  """

  use Ash.Resource,
    domain: ClinicDemo.EvidenceSpike,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? false
  end

  code_interface do
    define :record
    define :list, action: :read
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      accept :*
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:extraction, :proposal, :check, :verification]]

    attribute :run_id, :string, allow_nil?: false, public?: true
    attribute :certificate_id, :string, allow_nil?: false, public?: true
    attribute :path, :atom, public?: true, constraints: [one_of: [:static, :enum]]
    attribute :field, :atom, public?: true
    attribute :value, :string, public?: true
    attribute :status, :atom, public?: true
    attribute :source_ids, {:array, :string}, public?: true, default: []
    attribute :probability, :float, public?: true
    attribute :passed, :boolean, public?: true
    attribute :detail, :string, public?: true
    attribute :raw_reply, :map, public?: true
    attribute :schema_hash, :string, public?: true
    attribute :model, :string, public?: true
    attribute :provenance, :string, public?: true
    attribute :latency_ms, :integer, public?: true
    attribute :output_tokens, :integer, public?: true

    create_timestamp :recorded_at
  end
end
