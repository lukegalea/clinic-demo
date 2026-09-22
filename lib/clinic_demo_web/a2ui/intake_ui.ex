defmodule ClinicDemoWeb.A2ui.IntakeUI do
  @moduledoc """
  Intake: take a new patient onto the books. The register action's
  validations (email format, date of birth) ride along from the action, and
  the recently-registered list below the form gives the receptionist
  immediate confirmation the animal landed. Booking follows one click away
  on the schedule — the booking form's patient picker searches by name.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Scheduling.Patient
    surface_id "clinic_intake"
    title "Intake"
    record_label("patient")
    spec_version "0.9.1"

    query :default do
      search_fields [:name, :owner_email]
      sortable [:name]
      default_sort name: :asc
      page_size 8
    end

    component :form do
      fields [
        :name,
        :species,
        :breed,
        :date_of_birth,
        :weight_kg,
        :microchip_number,
        :owner_email
      ]

      create_action :register
    end

    component :table, :recent do
      fields [:name, :species, :breed, :owner_email]
      read_action :read
      query :default

      row_layout do
        title :name
        meta [:species, :breed, :owner_email]
        columns 3
      end
    end

    field :date_of_birth do
      label "Born"
      format :date
    end

    field :owner_email do
      label "Owner"
    end
  end
end
