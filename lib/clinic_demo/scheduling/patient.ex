defmodule ClinicDemo.Scheduling.Patient do
  @moduledoc """
  An animal registered with the clinic.

  The owner is modelled as an email address rather than a resource of its
  own: this is a demo, and one fewer table keeps the introspection output
  readable.
  """

  use Ash.Resource,
    domain: ClinicDemo.Scheduling,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "patients"
    repo ClinicDemo.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      description "The animal's name, as the owner gives it."
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 60, trim?: true
    end

    attribute :species, :atom do
      description "Constrained rather than free text so the schedule can be filtered by it."
      allow_nil? false
      public? true
      constraints one_of: [:dog, :cat, :rabbit, :ferret, :bird, :reptile]
    end

    attribute :breed, :string do
      description "Free text. Breed vocabularies are not worth modelling at this size."
      public? true
      constraints max_length: 80, trim?: true
    end

    attribute :date_of_birth, :date do
      description "Often approximate for rescues, so it is optional."
      public? true
    end

    attribute :weight_kg, :decimal do
      description "Most recent recorded weight. Updated through :record_weight, never by hand."
      public? true
      constraints min: Decimal.new("0.01"), max: Decimal.new("120")
    end

    attribute :microchip_number, :string do
      description "ISO 11784 chip: exactly fifteen digits."
      public? true
      constraints match: ~r/^\d{15}$/
    end

    attribute :owner_email, :ci_string do
      description "Case-insensitive, because owners are inconsistent about capitals."
      allow_nil? false
      public? true
    end

    timestamps()
  end

  identities do
    identity :unique_microchip, [:microchip_number]
  end

  relationships do
    has_many :appointments, ClinicDemo.Scheduling.Appointment do
      description "Every appointment ever booked for this animal."
      public? true
      sort scheduled_at: :desc
    end
  end

  aggregates do
    # Public so the a2ui grids can show them — visit counts are grid
    # questions, asked per row.
    count :appointment_count, :appointments do
      public? true
    end

    count :completed_visit_count, :appointments do
      filter expr(status == :completed)
      public? true
    end

    max :last_seen_at, :appointments, :scheduled_at do
      filter expr(status == :completed)
      public? true
    end
  end

  calculations do
    calculate :age_in_days,
              :integer,
              ClinicDemo.Scheduling.Calculations.AgeInDays do
      description "Nil when the date of birth is unknown, which is common."
      public? true
    end

    calculate :age_band,
              :string,
              ClinicDemo.Scheduling.Calculations.AgeBand do
      description "Life stage, as the triage decision table reads it. Nil when the age is unknown."
      public? true
    end

    calculate :display_label, :string, expr(name <> " (" <> type(species, :string) <> ")") do
      public? true
    end
  end

  actions do
    default_accept []
    defaults [:read, :destroy]

    create :register do
      description "Take a new animal onto the books."

      accept [
        :name,
        :species,
        :breed,
        :date_of_birth,
        :weight_kg,
        :microchip_number,
        :owner_email
      ]

      validate match(:owner_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/) do
        message "must be a deliverable email address"
      end

      validate compare(:date_of_birth, less_than_or_equal_to: &Date.utc_today/0) do
        where present(:date_of_birth)
        message "cannot be in the future"
      end
    end

    update :record_weight do
      description "Log a weigh-in. The only sanctioned way to change :weight_kg."

      accept []

      argument :weight_kg, :decimal do
        description "Weight in kilograms, as read off the scale."
        allow_nil? false
        constraints min: Decimal.new("0.01"), max: Decimal.new("120")
      end

      change set_attribute(:weight_kg, arg(:weight_kg))
    end
  end
end
