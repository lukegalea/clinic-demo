defmodule ClinicDemo.Scheduling do
  @moduledoc """
  Appointment scheduling for a small veterinary clinic.

  Three resources — a patient (the animal), a clinician, and the appointment
  that joins them — plus the code interface the rest of the application calls.
  Mobile visits add three: `ServiceLocation`, `TravelMatrix` (a versioned, immutable
  data artifact) and `VisitRequest` (temporal; scheduled only by applying a plan).
  The weekly roster adds four more: `Availability` (temporal), `ShiftTemplate`,
  and the two resources a roster candidate creates when a person applies it,
  `Shift` and `Assignment`.

  Every function below is generated from an action on a resource. That is the
  point of the demo: the contract an agent needs to call this code is already
  declared, so it can be read rather than guessed at.
  """

  use Ash.Domain

  resources do
    resource ClinicDemo.Scheduling.Patient do
      define :register_patient, action: :register
      define :list_patients, action: :read
      define :get_patient, action: :read, get_by: [:id]
      define :record_weight, action: :record_weight, args: [:weight_kg]
    end

    resource ClinicDemo.Scheduling.Clinician do
      define :hire_clinician, action: :create
      define :list_clinicians, action: :read
      define :get_clinician, action: :read, get_by: [:id]
      define :retire_clinician, action: :retire
    end

    resource ClinicDemo.Scheduling.Appointment do
      define :book_appointment, action: :book
      define :list_appointments, action: :read
      define :get_appointment, action: :read, get_by: [:id]
      define :appointments_in_window, action: :in_window, args: [:from, :to]
      define :check_in_appointment, action: :check_in
      define :complete_appointment, action: :complete, args: [:notes]
      define :reschedule_appointment, action: :reschedule, args: [:scheduled_at]
      define :cancel_appointment, action: :cancel, args: [:reason]
      define :record_appointment_triage, action: :record_triage, args: [:urgency]
      define :mark_appointment_no_show, action: :mark_no_show
      define :discharge_appointment, action: :discharge
    end

    resource ClinicDemo.Scheduling.AppointmentType do
      define :list_appointment_types, action: :read
      define :get_appointment_type, action: :read, get_by: [:id]
    end

    resource ClinicDemo.Scheduling.Availability do
      define :declare_availability, action: :declare
      define :list_availabilities, action: :read
      define :revise_availability, action: :revise
    end

    resource ClinicDemo.Scheduling.ShiftTemplate do
      define :define_shift_template, action: :define
      define :list_shift_templates, action: :read
      define :retire_shift_template, action: :retire
    end

    resource ClinicDemo.Scheduling.ServiceLocation do
      define :register_service_location, action: :register
      define :list_service_locations, action: :read
      define :get_service_location, action: :read, get_by: [:id]
      define :retire_service_location, action: :retire
    end

    resource ClinicDemo.Scheduling.TravelMatrix do
      define :publish_travel_matrix, action: :publish
      define :list_travel_matrices, action: :read
    end

    # A request is scheduled only by applying a mobile-visit candidate
    # (`ClinicDemo.Planning.Checks.AppliedByCandidate` gates `:schedule`).
    resource ClinicDemo.Scheduling.VisitRequest do
      define :request_visit, action: :request
      define :list_visit_requests, action: :read
      define :get_visit_request, action: :read, get_by: [:id]
      define :schedule_visit_request, action: :schedule, args: [:appointment_id]
      define :cancel_visit_request, action: :cancel, args: [:reason]
    end

    # Shifts and assignments are written only by applying a roster candidate
    # (`ClinicDemo.Planning.Checks.AppliedByCandidate` gates both).
    resource ClinicDemo.Scheduling.Shift do
      define :place_shift, action: :place
      define :list_shifts, action: :read
      define :cancel_shift, action: :cancel
    end

    resource ClinicDemo.Scheduling.Assignment do
      define :place_assignment, action: :place
      define :list_assignments, action: :read
      define :cancel_assignment, action: :cancel
    end
  end
end
