defmodule ClinicDemoWeb.A2ui.ClinicianUI do
  @moduledoc """
  Bookable staff. License number is required for veterinarians only — the
  create action enforces it, and the form inherits that too.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Scheduling.Clinician
    surface_id "clinic_clinicians"
    title "Clinicians"
    record_label("clinician")
    spec_version "0.9.1"

    query :default do
      search_fields [:full_name, :license_number]
      sortable [:full_name]
      filters [:role, :active]
      default_sort full_name: :asc
    end

    component :table do
      fields [:full_name, :role, :license_number, :active, :upcoming_appointment_count]
      read_action :read
      query :default
      row_actions [:retire]
    end

    component :form do
      fields [:full_name, :role, :license_number]
      create_action :create
    end

    action :retire do
      visible_when active: true
    end
  end
end
