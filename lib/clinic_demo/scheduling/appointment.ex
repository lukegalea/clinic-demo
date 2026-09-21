defmodule ClinicDemo.Scheduling.Appointment do
  @moduledoc """
  A booked slot: one patient, one clinician, one point in time.

  The lifecycle is deliberately explicit. There is no generic `:update`
  action — each transition is its own named action with its own arguments and
  its own guard, which is what makes the action contract worth reading.
  """

  use Ash.Resource,
    domain: ClinicDemo.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ClinicDemo.Scheduling.Validations.CurrentStatusIn
  alias ClinicDemo.Scheduling.Validations.NotInThePast

  postgres do
    table "appointments"
    repo ClinicDemo.Repo

    references do
      reference :patient, on_delete: :delete
      reference :clinician, on_delete: :restrict
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :scheduled_at, :utc_datetime do
      description "Start of the slot, always stored in UTC."
      allow_nil? false
      public? true
    end

    attribute :duration_minutes, :integer do
      description "Slot length. The clinic works in five-minute increments."
      allow_nil? false
      public? true
      default 30
      constraints min: 5, max: 240
    end

    attribute :reason, :string do
      description "Why the animal is coming in, in the owner's words."
      allow_nil? false
      public? true
      constraints min_length: 3, max_length: 200, trim?: true
    end

    attribute :status, :atom do
      description "Set only by the lifecycle actions below, never accepted as input."
      allow_nil? false
      public? true
      default :scheduled
      constraints one_of: [:scheduled, :checked_in, :completed, :cancelled, :no_show]
    end

    attribute :notes, :string do
      description "Clinical notes, written at completion."
      public? true
      constraints max_length: 4000
    end

    attribute :cancellation_reason, :string do
      public? true
      constraints max_length: 200, trim?: true
    end

    timestamps()
  end

  relationships do
    belongs_to :patient, ClinicDemo.Scheduling.Patient do
      description "The animal being seen."
      allow_nil? false
      public? true
    end

    belongs_to :clinician, ClinicDemo.Scheduling.Clinician do
      description "Who is seeing them."
      allow_nil? false
      public? true
    end
  end

  calculations do
    calculate :ends_at,
              :utc_datetime,
              expr(datetime_add(scheduled_at, duration_minutes, :minute)) do
      public? true
    end

    calculate :open?, :boolean, expr(status in [:scheduled, :checked_in]) do
      description "Still occupies a slot on the schedule."
      public? true
    end
  end

  actions do
    default_accept []
    defaults [:read]

    read :in_window do
      description "Everything on the schedule between two instants, earliest first."

      argument :from, :utc_datetime do
        description "Inclusive lower bound."
        allow_nil? false
      end

      argument :to, :utc_datetime do
        description "Exclusive upper bound."
        allow_nil? false
      end

      filter expr(scheduled_at >= ^arg(:from) and scheduled_at < ^arg(:to))

      prepare build(sort: [scheduled_at: :asc])
    end

    create :book do
      description "Put a new appointment on the schedule."

      accept [:scheduled_at, :duration_minutes, :reason]

      argument :patient_id, :uuid do
        description "An existing patient. Booking does not create one."
        allow_nil? false
      end

      argument :clinician_id, :uuid do
        description "An existing, active clinician."
        allow_nil? false
      end

      change manage_relationship(:patient_id, :patient, type: :append)
      change manage_relationship(:clinician_id, :clinician, type: :append)

      validate {NotInThePast, attribute: :scheduled_at}
    end

    update :reschedule do
      description "Move an existing appointment. Only open appointments can move."

      # Reads the prior status, so it cannot run as a single atomic statement.
      require_atomic? false

      accept []

      argument :scheduled_at, :utc_datetime do
        allow_nil? false
      end

      validate {CurrentStatusIn, from: [:scheduled, :checked_in]}
      validate {NotInThePast, attribute: :scheduled_at}

      change set_attribute(:scheduled_at, arg(:scheduled_at))
    end

    update :check_in do
      description "The animal has arrived."

      require_atomic? false

      accept []

      validate {CurrentStatusIn, from: [:scheduled]}

      change set_attribute(:status, :checked_in)
    end

    update :complete do
      description "The visit happened. Clinical notes are mandatory."

      require_atomic? false

      accept []

      argument :notes, :string do
        description "What was found and what was done."
        allow_nil? false
        constraints min_length: 10, max_length: 4000, trim?: true
      end

      validate {CurrentStatusIn, from: [:checked_in]}

      change set_attribute(:notes, arg(:notes))
      change set_attribute(:status, :completed)
    end

    update :cancel do
      description "Called off before it happened."

      require_atomic? false

      accept []

      argument :reason, :string do
        allow_nil? false
        constraints min_length: 3, max_length: 200, trim?: true
      end

      validate {CurrentStatusIn, from: [:scheduled, :checked_in]}

      change set_attribute(:cancellation_reason, arg(:reason))
      change set_attribute(:status, :cancelled)
    end
  end

  policies do
    policy action_type(:read) do
      description "The schedule is readable by anything that can reach the application."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only a signed-in member of staff may change the schedule."
      authorize_if actor_present()
    end
  end
end
