defmodule ClinicDemo.Events.Event do
  @moduledoc """
  One row of the `ash_events` event log, read-only.

  The table is created by the compliance install's migration and is written
  by ash_events' own machinery (not this application's code paths — the
  guard path here is synchronous and appends nothing today). This resource
  exists so the log is *visible*: an operator can read what happened,
  filtered and sorted like any other surface. There are deliberately no
  create/update/destroy actions — an audit log you can write to from the
  application is not an audit log.
  """

  use Ash.Resource,
    domain: ClinicDemo.Events,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "ash_events"
    repo ClinicDemo.Repo
  end

  actions do
    default_accept []
    defaults [:read]
  end

  attributes do
    attribute :id, :integer do
      allow_nil? false
      primary_key? true
      public? true
    end

    attribute :record_id, :uuid do
      description "The primary key of the record the event is about."
      allow_nil? false
      public? true
    end

    attribute :version, :integer do
      description "Event schema version, for replay compatibility."
      allow_nil? false
      public? true
    end

    attribute :resource, :string do
      description "The resource the event was recorded against."
      allow_nil? false
      public? true
    end

    attribute :action, :string do
      allow_nil? false
      public? true
    end

    attribute :action_type, :string do
      allow_nil? false
      public? true
    end

    attribute :data, :map do
      description "The action's input data."
      allow_nil? false
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
    end

    attribute :changed_attributes, :map do
      description "Attributes changed but not present in the original action input."
      allow_nil? false
      public? true
    end

    attribute :occurred_at, :naive_datetime do
      description "When the event was recorded (UTC, naive — the table's column type)."
      allow_nil? false
      public? true
    end

    attribute :user_id, :uuid do
      description "The acting user's primary key, when persisted by the writer."
      public? true
    end

    attribute :practice_id, :uuid do
      description "The acting practice/system actor's key, when persisted by the writer."
      public? true
    end
  end

  calculations do
    calculate :what, :string, expr(action <> " on " <> resource) do
      description "One-line subject for the audit feed."
      public? true
    end
  end

  policies do
    policy action_type(:read) do
      description "Audit visibility is read-only and available to anyone who can reach the application."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "There is no sanctioned write to the event log from this application."
      forbid_if always()
    end
  end
end
