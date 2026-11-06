defmodule ClinicDemo.Scheduling.Assignment do
  @moduledoc """
  Who covers an appointment: the roster's per-appointment output once a person
  has applied it.

  An assignment does not touch the appointment. The booking (time, patient,
  `clinician_id`) is the customer's commitment and the solver never moves it;
  the assignment says which clinician the roster has committed to cover it. Like
  a `Shift`, it is **created only by applying a candidate**
  (`ClinicDemo.Planning.Checks.AppliedByCandidate`) and a replan cancels rather
  than edits it.

  `appointment_id` is a plain pointer: `Appointment` is temporal, and a database
  foreign key cannot reference a temporal key, so the pointer is resolved as of a
  chosen instant where it is read.
  """

  use Ash.Resource,
    domain: ClinicDemo.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table "scheduling_assignments"
    repo ClinicDemo.Repo

    references do
      reference :clinician, on_delete: :restrict
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :appointment_id, :uuid do
      description "The appointment covered. A pointer, not a foreign key (the target is temporal)."
      allow_nil? false
      public? true
    end

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:veterinarian, :technician, :nurse]
    end

    attribute :state, :atom do
      description "Set by the lifecycle actions, never accepted as input."
      allow_nil? false
      public? true
      default :scheduled
      constraints one_of: [:scheduled, :cancelled]
    end

    attribute :candidate_id, :uuid do
      description "The applied roster candidate that placed this assignment."
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
  end

  events do
    event_log(ClinicDemo.Events.Event)
  end

  actions do
    default_accept []
    defaults [:read]

    create :place do
      description "Cover an appointment with a clinician. Only while a roster candidate is being applied."
      accept [:appointment_id, :role, :candidate_id]

      argument :clinician_id, :uuid, allow_nil?: false

      change manage_relationship(:clinician_id, :clinician, type: :append)
      change ClinicDemo.Planning.Changes.StartOperatingProcess
    end

    update :cancel do
      description "Cancel a placed assignment because a newer applied candidate replaces it."
      accept []

      validate attribute_equals(:state, :scheduled),
        message: "only a scheduled assignment is cancelled"

      change set_attribute(:state, :cancelled)
    end
  end

  policies do
    policy action_type(:read) do
      description "Assignments are readable by anything that can reach the application."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description """
      Assignments exist only because an approved roster candidate was applied: no
      person creates, edits or deletes one directly.
      """

      authorize_if ClinicDemo.Planning.Checks.AppliedByCandidate
    end
  end
end
