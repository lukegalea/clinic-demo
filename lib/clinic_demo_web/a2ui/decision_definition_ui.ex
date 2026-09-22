defmodule ClinicDemoWeb.A2ui.DecisionDefinitionUI do
  @moduledoc """
  The published decision tables — how urgency is decided, and which version
  is live. Read-only like the process definitions: rules change through
  `ClinicDemo.Rules`, and that is the point of them.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Decisions.Definition
    surface_id "clinic_decision_definitions"
    title "Decision tables"
    record_label("decision definition")
    spec_version "0.9.1"

    query :default do
      sortable [:key, :version]
      filters [:status]
      default_sort key: :asc
    end

    component :table do
      fields [:key, :name, :version, :status]
      read_action :read
      query :default
    end
  end
end
