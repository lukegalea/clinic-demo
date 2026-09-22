defmodule ClinicDemoWeb.A2ui.PatientUI do
  @moduledoc """
  Registered animals. The form is the register action — the email-format and
  not-yet-born validations live on the action, so the form inherits them.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Scheduling.Patient
    surface_id "clinic_patients"
    title "Patients"
    record_label("patient")
    spec_version "1.0"

    query :default do
      search_fields [:name, :breed, :owner_email]
      sortable [:name]
      filters [:species]
      default_sort name: :asc
    end

    component :table do
      fields [
        :name,
        :species,
        :breed,
        :date_of_birth,
        :weight_kg,
        :owner_email,
        :appointment_count
      ]

      read_action :read
      query :default
      row_actions [:record_weight]
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

    action :record_weight do
      prompt_fields [:weight_kg]
      prompt_title "Record weight"
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
