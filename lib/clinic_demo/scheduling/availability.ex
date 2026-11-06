defmodule ClinicDemo.Scheduling.Availability do
  @moduledoc """
  Whether a clinician can work a stretch of one day: the input the weekly
  roster respects.

  A row names a clinician, a calendar `date`, and a half-open interval
  `[starts_at, ends_at)` inside it, with an `available` flag and a `reason`.
  A stretch no row speaks for is available (the shift templates say when the
  clinic is open); `available: false` is what removes it from the roster.

  The resource is **temporal** (`strategy :context`, period `valid_at`), the
  same way `Appointment` is: removing a clinician's availability is a
  period-splitting write, so what the roster was told as of last Monday stays
  readable as of last Monday. The roster's snapshot reads this table `as_of` its
  knowledge cutoff, which is what lets a plan be replayed against the
  availability it actually saw.

  Synthetic data only: a reason is a short code-like phrase ("leave", "course"),
  never a person's circumstances.
  """

  use Ash.Resource,
    domain: ClinicDemo.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table "scheduling_availabilities"
    repo ClinicDemo.Repo

    references do
      reference :clinician, on_delete: :restrict
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :date, :date do
      description "The calendar day (UTC) the interval falls on."
      allow_nil? false
      public? true
    end

    attribute :starts_at, :utc_datetime do
      description "Start of the interval, inclusive."
      allow_nil? false
      public? true
    end

    attribute :ends_at, :utc_datetime do
      description "End of the interval, exclusive."
      allow_nil? false
      public? true
    end

    attribute :available, :boolean do
      description "False removes the clinician from the roster for the interval."
      allow_nil? false
      public? true
      default true
    end

    attribute :reason, :string do
      description "A short reason code or phrase; never a personal circumstance."
      public? true
      constraints max_length: 80, trim?: true
    end

    timestamps()
  end

  relationships do
    # The destination is not temporal, this side is: `{source, destination}`.
    belongs_to :clinician, ClinicDemo.Scheduling.Clinician do
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

    create :declare do
      description "Record whether a clinician is available for an interval of one day."
      accept [:starts_at, :ends_at, :available, :reason]

      argument :clinician_id, :uuid do
        allow_nil? false
      end

      change manage_relationship(:clinician_id, :clinician, type: :append)
      change ClinicDemo.Scheduling.Changes.DeriveAvailabilityDate
      validate ClinicDemo.Scheduling.Validations.IntervalWithinOneDay
    end

    update :revise do
      description """
      Change whether the interval is available (and why), from `as_of` onward.
      The interval and the clinician never change; a different interval is a
      new declaration.
      """

      accept [:available, :reason]
    end
  end

  policies do
    policy action_type(:read) do
      description "Availability is readable by anything that can reach the application."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only a signed-in member of staff may declare or revise availability."
      authorize_if actor_present()
    end
  end
end
