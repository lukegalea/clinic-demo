defmodule ClinicDemo.Fhir.Encounter do
  @moduledoc """
  A visit, in FHIR R4's `Encounter` vocabulary. A façade over
  `ClinicDemo.Scheduling.Appointment`.

  ## Status is a decode lens

  | Appointment status | `Encounter.status` |
  |---|---|
  | `:scheduled` | `:planned` |
  | `:checked_in` | `:arrived` |
  | `:completed` | `:finished` |
  | `:cancelled` | `:cancelled` |
  | `:no_show` | `:no_show` |

  The appointment has no state between check-in and write-up, so there is no
  `:in_progress`: the façade does not invent one. `:no_show` is not an R4
  `Encounter.status` value; it keeps the appointment's own fact rather than
  folding it into `:cancelled`, where the two would no longer decode back.

  ## Writes go through named actions only

  The façade declares two writes and no generic update:

    * `:finish` runs the appointment's `:complete` (status becomes `:finished`;
      the clinical note is required there).
    * `:cancel` runs the appointment's `:cancel` (status becomes `:cancelled`;
      a reason is required there).

  Any other status change has no action here to run. A write takes effect now:
  one carrying `as_of` is refused before the appointment is touched. Reads
  accept `as_of` and pass it to the appointment, which is temporal.
  """

  use Ash.Resource,
    domain: ClinicDemo.Fhir,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true

    attribute :status, :atom,
      public?: true,
      constraints: [one_of: [:planned, :arrived, :finished, :cancelled, :no_show]]

    attribute :class, :atom,
      public?: true,
      constraints: [one_of: [:ambulatory, :home, :virtual]]

    attribute :subject_id, :uuid, public?: true
    attribute :practitioner_id, :uuid, public?: true
    attribute :location_id, :uuid, public?: true
    attribute :period_start, :utc_datetime, public?: true
    attribute :length_minutes, :integer, public?: true
    attribute :reason, :string, public?: true
    attribute :note, :string, public?: true
    attribute :cancellation_reason, :string, public?: true
  end

  facade do
    source ClinicDemo.Scheduling.Appointment
    read_action :read

    map(:id, from: :id)

    decode(:status,
      from: :status,
      values: %{
        scheduled: :planned,
        checked_in: :arrived,
        completed: :finished,
        cancelled: :cancelled,
        no_show: :no_show
      }
    )

    decode(:class,
      from: :location_mode,
      values: %{in_clinic: :ambulatory, mobile: :home, telehealth: :virtual}
    )

    map(:subject_id, from: :patient_id)
    map(:practitioner_id, from: :clinician_id)
    map(:location_id, from: :service_location_id)
    map(:period_start, from: :scheduled_at)
    map(:length_minutes, from: :duration_minutes)
    map(:reason, from: :reason)
    map(:note, from: :notes)
    map(:cancellation_reason, from: :cancellation_reason)

    hide(:severity, because: "Triage inputs are the clinic's, not part of the encounter.")
    hide(:triage_urgency, because: "Triage inputs are the clinic's, not part of the encounter.")
    defer(:discharged_at)
    defer(:appointment_type_id)
    hide(:inserted_at, because: "Row bookkeeping.")
    hide(:updated_at, because: "Row bookkeeping.")

    hide(:valid_at,
      because: "The version's period is read through `as_of`, not carried as a field."
    )

    write(:finish, via: :complete, sets: [status: :finished], accepts: [:note])
    write(:cancel, via: :cancel, sets: [status: :cancelled], accepts: [:cancellation_reason])
  end
end
