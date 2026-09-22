defmodule ClinicDemoWeb.A2ui.VisitInstanceUI do
  @moduledoc """
  The visit processes: where each instance stands (its live token's node),
  about what (the patient and booking reason), and how it ended.

  Read-only by construction — the surface has no row actions because
  instances advance through the worklist, never by hand.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Visits.Instance
    surface_id "clinic_visits"
    title "Visit processes"
    record_label("visit")
    spec_version "0.9.1"

    query :default do
      sortable [:status, :outcome]
      filters [:status]
      default_sort status: :asc
      page_size 25
    end

    component :table do
      fields [:subject_label, :current_node, :status, :outcome]
      read_action :read
      query :default

      row_layout do
        title :subject_label
        badge :status
        meta [:current_node, :outcome]
        columns 2
      end
    end

    field :subject_label do
      label "About"
    end

    field :current_node do
      label "Standing at"
    end
  end
end
