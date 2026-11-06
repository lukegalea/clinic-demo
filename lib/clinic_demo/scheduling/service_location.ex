defmodule ClinicDemo.Scheduling.ServiceLocation do
  @moduledoc """
  A place the clinic's veterinarian works from or drives to: the clinic itself, or
  a client's address for a mobile visit.

  The travel matrix (`ClinicDemo.Scheduling.TravelMatrix`) is keyed by these ids,
  so a location is the unit of "from" and "to"; two visits at one location need no
  travel between them.

  Addresses and coordinates are **synthetic** (this is a demo: no fixture names a
  real street or client). `access_constraints` and `access_buffer_minutes` are what
  a mobile visit needs *at* the door: gates, stairs and parking add minutes to the
  service time the planner reserves, so a visit that looks like thirty minutes on
  the schedule is planned as thirty plus the buffer.
  """

  use Ash.Resource,
    domain: ClinicDemo.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table "scheduling_service_locations"
    repo ClinicDemo.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      description "What the front desk calls the place, e.g. \"Maple Row farm\"."
      allow_nil? false
      public? true
      constraints min_length: 2, max_length: 80, trim?: true
    end

    attribute :kind, :atom do
      description "The clinic (where a day starts and ends) or a client's site."
      allow_nil? false
      public? true
      default :client_site
      constraints one_of: [:clinic, :client_site]
    end

    attribute :address_line, :string do
      description "Synthetic street address."
      allow_nil? false
      public? true
      constraints max_length: 120, trim?: true
    end

    attribute :city, :string do
      allow_nil? false
      public? true
      constraints max_length: 60, trim?: true
    end

    attribute :postal_code, :string do
      public? true
      constraints max_length: 12, trim?: true
    end

    attribute :latitude, :decimal do
      description "Synthetic latitude in degrees. Never a float."
      allow_nil? false
      public? true
      constraints min: Decimal.new("-90"), max: Decimal.new("90")
    end

    attribute :longitude, :decimal do
      description "Synthetic longitude in degrees. Never a float."
      allow_nil? false
      public? true
      constraints min: Decimal.new("-180"), max: Decimal.new("180")
    end

    attribute :access_constraints, {:array, :atom} do
      description "What the veterinarian meets at the door."
      allow_nil? false
      public? true
      default []

      constraints items: [
                    one_of: [
                      :gated_entry,
                      :stairs_only,
                      :restricted_parking,
                      :appointment_only_access
                    ]
                  ]
    end

    attribute :access_buffer_minutes, :integer do
      description """
      Minutes added to a visit's service time for getting in and set up (gate codes,
      stairs, a long walk from parking). Planned time, never booked time.
      """

      allow_nil? false
      public? true
      default 0
      constraints min: 0, max: 60
    end

    attribute :active, :boolean do
      allow_nil? false
      public? true
      default true
    end

    timestamps()
  end

  events do
    event_log(ClinicDemo.Events.Event)
  end

  actions do
    default_accept []
    defaults [:read]

    create :register do
      description "Add a place the veterinarian can be sent to, or start the day from."

      accept [
        :name,
        :kind,
        :address_line,
        :city,
        :postal_code,
        :latitude,
        :longitude,
        :access_constraints,
        :access_buffer_minutes
      ]
    end

    update :retire do
      description "Stop offering the location. Visits already booked there keep it."
      accept []
      change set_attribute(:active, false)
    end
  end

  policies do
    policy action_type(:read) do
      description "Locations are readable by anything that can reach the application."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only a signed-in member of staff may change the location catalogue."
      authorize_if actor_present()
    end
  end
end
