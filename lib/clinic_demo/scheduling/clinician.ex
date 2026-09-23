defmodule ClinicDemo.Scheduling.Clinician do
  @moduledoc """
  Someone who can be booked: a vet, a technician, or a nurse.
  """

  use Ash.Resource,
    domain: ClinicDemo.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table "clinicians"
    repo ClinicDemo.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :full_name, :string do
      allow_nil? false
      public? true
      constraints min_length: 2, max_length: 80, trim?: true
    end

    attribute :role, :atom do
      description "Determines what kinds of appointment may be booked against them."
      allow_nil? false
      public? true
      default :veterinarian
      constraints one_of: [:veterinarian, :technician, :nurse]
    end

    attribute :license_number, :string do
      description "Provincial licence, formatted like ON-123456. Vets only."
      public? true
      constraints match: ~r/^[A-Z]{2}-\d{6}$/
    end

    attribute :active, :boolean do
      description "Inactive clinicians keep their history but take no new bookings."
      allow_nil? false
      public? true
      default true
    end

    timestamps()
  end

  # Hires and retirements change who can act: they are audit-log material
  # like every other story resource's write.
  events do
    event_log(ClinicDemo.Events.Event)
  end

  identities do
    identity :unique_license, [:license_number]
  end

  relationships do
    has_many :appointments, ClinicDemo.Scheduling.Appointment do
      public? true
    end
  end

  aggregates do
    count :upcoming_appointment_count, :appointments do
      filter expr(status in [:scheduled, :checked_in])
      public? true
    end
  end

  actions do
    default_accept []
    defaults [:read, :destroy]

    create :create do
      description "Add a clinician to the roster."
      primary? true
      accept [:full_name, :role, :license_number]

      validate present(:license_number) do
        where attribute_equals(:role, :veterinarian)
        message "is required for veterinarians"
      end
    end

    update :retire do
      description "Take a clinician off the roster without deleting their history."
      accept []
      change set_attribute(:active, false)
    end
  end

  # Same two-policy shape as Appointment: reads are open, writes need someone
  # acting. The audit flipped Active -> false on a clinician with nobody
  # acting; the actor picker itself still lists the roster, because its reads
  # are infrastructural and run with authorize?: false.
  policies do
    policy action_type(:read) do
      description "The roster is readable by anything that can reach the application."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only a signed-in member of staff may change the roster."
      authorize_if actor_present()
    end
  end
end
