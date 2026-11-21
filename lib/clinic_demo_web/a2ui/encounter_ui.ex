defmodule ClinicDemoWeb.A2ui.EncounterUI do
  @moduledoc """
  Encounters: the visits, in FHIR R4's `Encounter` vocabulary, as a read-only
  list. The rows are `ClinicDemo.Fhir.Encounter`, a façade over the
  appointments, so each read runs the appointment read as the viewer.

  The list carries no row actions: an encounter is finished or cancelled by
  the façade's named writes (`ClinicDemo.Fhir.finish_encounter/3`,
  `ClinicDemo.Fhir.cancel_encounter/3`), and the schedule is where visits are
  worked.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Fhir.Encounter
    surface_id "clinic_encounters"
    title "Encounters"
    record_label("encounter")

    query :default do
      sortable [:period_start]
      filters [:status, :class]
      default_sort period_start: :desc
    end

    component :table do
      fields [:period_start, :status, :class, :reason, :length_minutes]
      read_action :read
      query :default
    end

    field :period_start do
      label "Start"
    end

    field :length_minutes do
      label "Minutes"
    end
  end
end
