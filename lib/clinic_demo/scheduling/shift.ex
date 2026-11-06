defmodule ClinicDemo.Scheduling.Shift do
  @moduledoc """
  A clinician working a stretch of a day: the roster's output once a person has
  applied it.

  **Created only by applying a candidate.** There is no create a person can call
  directly: `:place` is authorized only while a four-eyes-approved roster
  candidate is being applied (`ClinicDemo.Planning.Checks.AppliedByCandidate`),
  and the row records which candidate placed it. A replan that moves a shift
  cancels the old row (`:cancel`, under the same gate) rather than editing it, so
  the history of what the clinic was told stays readable.

  Half-open interval `[starts_at, ends_at)`, inside one UTC day.
  """

  use Ash.Resource,
    domain: ClinicDemo.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table "scheduling_shifts"
    repo ClinicDemo.Repo

    references do
      reference :clinician, on_delete: :restrict
      reference :shift_template, on_delete: :restrict
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:veterinarian, :technician, :nurse]
    end

    attribute :starts_at, :utc_datetime do
      description "Start of the shift, inclusive."
      allow_nil? false
      public? true
    end

    attribute :ends_at, :utc_datetime do
      description "End of the shift, exclusive."
      allow_nil? false
      public? true
    end

    attribute :state, :atom do
      description "Set by the lifecycle actions, never accepted as input."
      allow_nil? false
      public? true
      default :scheduled
      constraints one_of: [:scheduled, :cancelled]
    end

    attribute :candidate_id, :uuid do
      description "The applied roster candidate that placed this shift."
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :clinician, ClinicDemo.Scheduling.Clinician do
      allow_nil? false
      public? true
    end

    belongs_to :shift_template, ClinicDemo.Scheduling.ShiftTemplate do
      description "The pattern this shift instantiates."
      public? true
    end
  end

  events do
    event_log(ClinicDemo.Events.Event)
  end

  actions do
    default_accept []
    defaults [:read]

    create :place do
      description "Put a clinician on shift. Only while a roster candidate is being applied."
      accept [:role, :starts_at, :ends_at, :candidate_id]

      argument :clinician_id, :uuid, allow_nil?: false
      argument :shift_template_id, :uuid

      change manage_relationship(:clinician_id, :clinician, type: :append)

      change manage_relationship(:shift_template_id, :shift_template, type: :append),
        where: [present(:shift_template_id)]

      validate ClinicDemo.Scheduling.Validations.IntervalWithinOneDay
    end

    update :cancel do
      description "Cancel a placed shift because a newer applied candidate replaces it."
      accept []

      validate attribute_equals(:state, :scheduled),
        message: "only a scheduled shift is cancelled"

      change set_attribute(:state, :cancelled)
    end
  end

  policies do
    policy action_type(:read) do
      description "The roster is readable by anything that can reach the application."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description """
      Shifts exist only because an approved roster candidate was applied: no
      person creates, edits or deletes one directly.
      """

      authorize_if ClinicDemo.Planning.Checks.AppliedByCandidate
    end
  end
end
