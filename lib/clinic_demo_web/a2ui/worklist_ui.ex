defmodule ClinicDemoWeb.A2ui.WorklistUI do
  @moduledoc """
  The worklist: human tasks waiting on a person, completed through the
  engine so the token advances with the outcome.

  Completing without claiming is deliberate — the engine records an implicit
  claim — so one row action carries the whole interaction.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Visits.HumanTask
    surface_id "clinic_worklist"
    title "Worklist"
    record_label("task")
    spec_version "0.9.1"

    query :default do
      sortable [:node_id, :status, :due_at]
      filters [:status, :node_id]
      default_sort status: :asc
      page_size 25

      preset :open do
        filter status: [:open, :claimed]
      end

      default_preset :open
    end

    component :table do
      fields [:name, :node_id, :status, :due_at]
      read_action :read
      query :default

      row_layout do
        title :name
        badge :status
        meta [:node_id, :due_at]
        columns 2
      end

      row_actions [:a2ui_complete]
    end

    action :a2ui_complete do
      prompt_fields [:outcome, :comment]
      prompt_title "Complete task"
      visible_when status: [:open, :claimed]
    end

    field :node_id do
      label "Step"
    end

    field :due_at do
      label "Due"
    end
  end
end
