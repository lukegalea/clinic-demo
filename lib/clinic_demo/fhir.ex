defmodule ClinicDemo.Fhir do
  @moduledoc """
  The scheduling resources in a second vocabulary: names taken from HL7 FHIR
  R4 (`Patient`, `Practitioner`, `Location`, `Encounter`), over the rows of
  `ClinicDemo.Scheduling`.

  These are façades (`AshStrangler.Facade`): resources with no table. A read
  runs the source's read as the caller; a write runs one named source action as
  the caller. Every fact keeps one record, on the scheduling resource, so the
  scheduling policies, the state machine and the audit log decide exactly as
  they do for every other caller, and nothing here restates them.

  The vocabulary is named after FHIR R4. It claims no conformance to it: the
  resources carry the names and value sets the clinic's rows can answer, and
  nothing else (no profiles, no terminology bindings, no REST interface).
  """

  use Ash.Domain

  resources do
    resource ClinicDemo.Fhir.Patient do
      define :list_fhir_patients, action: :read
    end

    resource ClinicDemo.Fhir.Practitioner do
      define :list_fhir_practitioners, action: :read
    end

    resource ClinicDemo.Fhir.Location do
      define :list_fhir_locations, action: :read
    end

    resource ClinicDemo.Fhir.Encounter do
      define :list_encounters, action: :read
      define :finish_encounter, action: :finish, args: [:id, :note]
      define :cancel_encounter, action: :cancel, args: [:id, :cancellation_reason]
    end
  end
end
