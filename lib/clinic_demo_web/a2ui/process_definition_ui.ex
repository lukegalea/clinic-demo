defmodule ClinicDemoWeb.A2ui.ProcessDefinitionUI do
  @moduledoc """
  The published visit processes. Read-only by construction — definitions
  change through `ClinicDemo.Rules`, never by hand from a grid. The XML stays
  out of the surface; what a person needs is which version of which process
  is live.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Visits.Definition
    surface_id "clinic_process_definitions"
    title "Visit processes"
    record_label("process definition")
    spec_version "1.0"

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
