defmodule ClinicDemo.EvidenceSpike.Proposal do
  @moduledoc """
  The constraint shape of one proposed field: `{value, status, source_ids}`.

  In its own module because `ClinicDemo.EvidenceSpike.Extraction` calls it while
  compiling its DSL, which a function in that same module cannot serve.
  """

  @statuses [:found, :not_found, :ambiguous]

  @doc "The status values. `:not_found` and `:ambiguous` are the abstentions."
  def statuses, do: @statuses

  @doc """
  The `:map` constraints for one proposal: `value` of the given type, a
  status, and cited atom ids.

  `source_ids` items are shape-checked (`a` and two digits) but not
  enumerated. The static schema cannot know which atoms a given packet has, so
  a model can cite an id that is not in the packet. Measuring how often that
  happens is one of the spike's questions. The per-call path
  (`ClinicDemo.EvidenceSpike.Extractor.extract_with_enum/2`) replaces the
  shape check with the packet's own ids.
  """
  def proposal(value_type, value_constraints \\ []) do
    [
      fields: [
        value: [type: value_type, allow_nil?: true, constraints: value_constraints],
        status: [type: :atom, allow_nil?: false, constraints: [one_of: @statuses]],
        source_ids: [
          type: {:array, :string},
          allow_nil?: false,
          constraints: [items: [match: ~r/^a\d{2}$/]]
        ]
      ]
    ]
  end
end
