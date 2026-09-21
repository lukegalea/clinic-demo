defmodule ClinicDemo.Scheduling do
  @moduledoc """
  Appointment scheduling for a small veterinary clinic.

  Three resources — a patient (the animal), a clinician, and the appointment
  that joins them — plus the code interface the rest of the application calls.

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
      define :cancel_appointment, action: :cancel, args: [:reason]
    end
  end
end
