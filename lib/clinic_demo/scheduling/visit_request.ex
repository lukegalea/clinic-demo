defmodule ClinicDemo.Scheduling.VisitRequest do
  @moduledoc """
  A request for a **mobile visit**: a patient, a kind of visit, a place, and an
  explicit window `[earliest_start_at, latest_end_at)` inside one UTC day that the
  whole visit (service time included) must fit in.

  A request is what the mobile-visit plan consumes; the booked `Appointment`
  (`location_mode: :mobile`) is what a plan produces. The states:

    * `:requested` — asked for, not on the schedule;
    * `:scheduled` — a four-eyes-approved plan was applied: `appointment_id` names
      the mobile appointment it booked;
    * `:cancelled` — called off. Cancelling a scheduled request cancels its
      appointment in the same transaction.

  **Scheduling is only by applying a plan.** `:schedule` is authorized only while a
  four-eyes-approved mobile-visit candidate is being applied
  (`ClinicDemo.Planning.Checks.AppliedByCandidate`, the same gate `Shift` and
  `Assignment` use); no person marks a request scheduled by hand.

  The resource is **temporal** (`strategy :context`, period `valid_at`) like
  `Appointment` and `Availability`: a cancellation is a period-splitting write, so
  the plan's snapshot reads the requests `as_of` its knowledge cutoff and a replay
  sees the requests the dispatcher saw. `appointment_id` is a plain id, not a
  relationship: the appointment is temporal and keyed by period.
  """

  use Ash.Resource,
    domain: ClinicDemo.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table "scheduling_visit_requests"
    repo ClinicDemo.Repo

    references do
      reference :patient, on_delete: :delete
      reference :appointment_type, on_delete: :restrict
      reference :service_location, on_delete: :restrict
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :earliest_start_at, :utc_datetime do
      description "The visit may not start before this instant (window start, inclusive)."
      allow_nil? false
      public? true
    end

    attribute :latest_end_at, :utc_datetime do
      description "The visit, service included, must be over by this instant (window end)."
      allow_nil? false
      public? true
    end

    attribute :duration_minutes, :integer do
      description "Booked length of the visit, in five-minute increments."
      allow_nil? false
      public? true
      default 30
      constraints min: 5, max: 240
    end

    attribute :reason, :string do
      description "Why the animal needs a visit, in the owner's words."
      allow_nil? false
      public? true
      constraints min_length: 3, max_length: 200, trim?: true
    end

    attribute :state, :atom do
      description "Set by the lifecycle actions below, never accepted as input."
      allow_nil? false
      public? true
      default :requested
      constraints one_of: [:requested, :scheduled, :cancelled]
    end

    attribute :appointment_id, :uuid do
      description "The mobile appointment a plan booked for the request. Set only on apply."
      public? true
    end

    attribute :cancellation_reason, :string do
      public? true
      constraints max_length: 200, trim?: true
    end

    timestamps()
  end

  relationships do
    # The destinations are not temporal, this side is: `{source, destination}`.
    belongs_to :patient, ClinicDemo.Scheduling.Patient do
      allow_nil? false
      public? true
      temporal_keys {:valid_at, nil}
    end

    belongs_to :appointment_type, ClinicDemo.Scheduling.AppointmentType do
      allow_nil? false
      public? true
      temporal_keys {:valid_at, nil}
    end

    belongs_to :service_location, ClinicDemo.Scheduling.ServiceLocation do
      allow_nil? false
      public? true
      temporal_keys {:valid_at, nil}
    end
  end

  events do
    event_log(ClinicDemo.Events.Event)
  end

  temporal do
    strategy :context
    attribute :valid_at
  end

  actions do
    default_accept []
    defaults [:read]

    create :request do
      description "Ask for a mobile visit inside a window of one day."

      accept [:earliest_start_at, :latest_end_at, :duration_minutes, :reason]

      argument :patient_id, :uuid, allow_nil?: false
      argument :appointment_type_id, :uuid, allow_nil?: false
      argument :service_location_id, :uuid, allow_nil?: false

      change manage_relationship(:patient_id, :patient, type: :append)
      change manage_relationship(:appointment_type_id, :appointment_type, type: :append)
      change manage_relationship(:service_location_id, :service_location, type: :append)

      validate {ClinicDemo.Scheduling.Validations.IntervalWithinOneDay,
                starts: :earliest_start_at, ends: :latest_end_at}

      validate ClinicDemo.Scheduling.Validations.WindowHoldsDuration
      validate {ClinicDemo.Scheduling.Validations.NotInThePast, attribute: :earliest_start_at}
    end

    update :schedule do
      description """
      Record that a plan booked the request. Only while a four-eyes-approved
      mobile-visit candidate is being applied.
      """

      require_atomic? false
      accept []

      argument :appointment_id, :uuid, allow_nil?: false

      validate attribute_equals(:state, :requested),
        message: "only a requested visit is scheduled"

      change set_attribute(:appointment_id, arg(:appointment_id))
      change set_attribute(:state, :scheduled)
    end

    update :cancel do
      description """
      Call the request off. A scheduled request cancels the appointment it booked
      in the same transaction. Pass the request's id (or a record read just now): the
      appointment is found on the record the action is given, so a stale copy that
      predates the booking would not know it had one.
      """

      require_atomic? false
      accept []

      argument :reason, :string do
        allow_nil? false
        constraints min_length: 3, max_length: 200, trim?: true
      end

      validate attribute_in(:state, [:requested, :scheduled]),
        message: "only an open request is cancelled"

      change set_attribute(:cancellation_reason, arg(:reason))
      change set_attribute(:state, :cancelled)
      change ClinicDemo.Scheduling.Changes.CancelLinkedAppointment
    end
  end

  policies do
    policy action_type(:read) do
      description "Visit requests are readable by anything that can reach the application."
      authorize_if always()
    end

    policy action([:request, :cancel]) do
      description "Only a signed-in member of staff may ask for or call off a mobile visit."
      authorize_if actor_present()
    end

    policy action(:schedule) do
      description """
      A request becomes scheduled only because an approved mobile-visit candidate is
      being applied: no person marks one scheduled directly.
      """

      authorize_if ClinicDemo.Planning.Checks.AppliedByCandidate
    end
  end
end
