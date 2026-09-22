defmodule ClinicDemoWeb.A2ui.EvaluationUI do
  @moduledoc """
  The decision evidence: every rule evaluation the clinic has run, which
  version of which table answered, and which rules matched. This is the
  "what did the rule decide, and why" view — the audit trail the DMN side
  writes for free.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Decisions.Evaluation
    surface_id "clinic_evaluations"
    title "Decision evidence"
    record_label("evaluation")
    spec_version "0.9.1"

    query :default do
      search_fields [:definition_key, :correlation_id]
      sortable [:definition_key, :definition_version]
      filters [:definition_key]
      default_sort definition_key: :asc
    end

    component :table do
      fields [
        :definition_key,
        :definition_version,
        :matched_rule_ids,
        :duration_us,
        :visit_label,
        :hit_policy
      ]

      read_action :read
      query :default

      row_layout do
        title :visit_label
        badge :definition_version
        meta [:matched_rule_ids, :duration_us, :definition_key, :hit_policy]
        columns 2
      end
    end

    field :definition_key do
      label "Decision"
    end

    field :definition_version do
      label "Version"
    end

    field :matched_rule_ids do
      label "Matched rules"
    end

    field :visit_label do
      label "Visit"
    end
  end
end
