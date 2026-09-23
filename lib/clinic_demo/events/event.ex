defmodule ClinicDemo.Events.Event do
  @moduledoc """
  One row of the `ash_events` event log.

  This is the log itself, through `AshEvents.EventLog`: every wrapped action
  on a story resource (appointments, patients, clinicians, DMN evaluations)
  appends a row here in the same transaction as its write, via ash_events'
  own machinery. The append path is the framework's — it runs with
  `authorize?: false` inside the writer's transaction — so the policy below
  governs the *application-facing* surface: there is no sanctioned create,
  update or destroy reachable through a normal authorized call. An audit log
  you can write to from the application is not an audit log.

  Read-side, the log is *visible*: an operator can read what happened,
  filtered and sorted like any other surface. The columns mirror the
  compliance install's `ash_events` migration exactly (it shipped the table
  before the log was wired), including `practice_id`, which ash_events does
  not populate in this app and which therefore stays a plain column.
  """

  use Ash.Resource,
    domain: ClinicDemo.Events,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.EventLog]

  postgres do
    table "ash_events"
    repo ClinicDemo.Repo
  end

  event_log do
    # The app's records are uuid-keyed, so `record_id` is a uuid (the default,
    # spelled out because it is a contract with the migration).
    record_id_type(:uuid)

    # Every field is operator-visible: this resource exists so the log can be
    # read. Without this the extension keeps everything private and the
    # /events surface would have nothing to render.
    public_fields(:all)

    # Attribution when the actor is a real struct. This demo's surfaces act
    # as bare `AshA2ui.Actor` structs and the seeds pass bare maps, so rows
    # written today carry a nil `user_id` by design — the column lights up
    # the day a Clinician struct stands behind an action.
    persist_actor_primary_key(:user_id, ClinicDemo.Scheduling.Clinician)
  end

  actions do
    default_accept []

    # The EventLog extension supplies the machinery's `:create` and the
    # `:replay` action; the operator surface gets only the plain read.
    defaults [:read]
  end

  calculations do
    calculate :what, :string, expr(type(action, :string) <> " on " <> type(resource, :string)) do
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
