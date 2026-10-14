defmodule ClinicDemo.Finance.Charge do
  @moduledoc """
  Money the clinic is owed for a visit, recognized when the visit was
  written up.

  One row per completed visit — the recognition hook on
  `Appointment.complete` creates it in the same transaction, so a visit and
  its charge exist together or not at all. The `amount` is a snapshot taken
  from the appointment type's `base_price` at completion: the catalogue can
  be repriced tomorrow without rewriting yesterday's revenue.

  The resource is **temporal** (`strategy :context`, period `valid_at`),
  exactly like `Appointment` — and for the same reasons. A charge's period
  starts at the write's `as_of`, which the hook sets to the completion's
  own instant, so `recognized_at` is the period's lower bound by
  construction and "what had the clinic recognized by instant T" is the
  plain containment read, `list_charges(as_of: t)`. The seeded history
  back-dates its completions, and the revenue view reads the money at any
  instant the board can read the schedule at — one time-travel grammar for
  both.
  """

  use Ash.Resource,
    domain: ClinicDemo.Finance,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  postgres do
    table "finance_charges"
    repo ClinicDemo.Repo

    custom_indexes do
      # The visit pointer is filtered/joined on by the recognition hook's
      # idempotency check; a plain FK is not possible either way — the
      # appointment's temporal primary key is (id, valid_at), so `id` alone
      # backs no unique index to reference.
      index [:appointment_id]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :appointment_id, :uuid do
      description "The visit this money is for — the audit log's join key, not a period join."
      allow_nil? false
      public? true
    end

    attribute :amount, :decimal do
      description """
      The visit's price, snapshotted from the catalogue at completion.
      A decimal or nothing — never a float.
      """

      allow_nil? false
      public? true
      constraints min: 0, max: 100_000
    end

    attribute :status, :atom do
      description "Set only by the lifecycle actions below, never accepted as input."
      allow_nil? false
      public? true
      default :paid
      constraints one_of: [:paid, :written_off]
    end

    attribute :recognized_at, :utc_datetime_usec do
      description """
      When the charge took effect — the completion's instant. This is the
      period's lower bound; the temporal read and this attribute agree by
      construction, not by a backfill.
      """

      allow_nil? false
      public? true
    end

    timestamps()
  end

  # A completed visit is audit-log material, and so is its money: the
  # recognition (and any write-off) lands in the log in the same
  # transaction as the write, like every story resource's.
  events do
    event_log(ClinicDemo.Events.Event)
  end

  # Temporal, same declaration as the appointment's — `valid_at` is added
  # by the extension, starts at the write's `as_of` (now unless the caller
  # passes one), and is never action input.
  temporal do
    strategy :context
    attribute :valid_at
  end

  relationships do
    # The plain-pointer shape the appointment's own relationships use:
    # WHICH visit the money is for — a fact that does not vary — so a plain
    # id join, no PERIOD foreign key. (A PERIOD join cannot even hold here:
    # the charge's period starts at the completion's instant, which no
    # single appointment *version's* period contains once the visit's
    # history has been split further.)
    # None. The visit pointer is a plain uuid attribute, deliberately: both
    # resources are temporal, and Ash insists a temporal -> temporal
    # relationship is a PERIOD foreign key — the referencing period must be
    # contained in some single referenced version's period. That can never
    # hold for money: a charge's period starts at the completion's instant
    # and runs forever, while the visit's history goes on being split
    # around it (the seeds re-assert every walked stage at the present), so
    # no one appointment version contains the charge's whole life. The
    # pointer is the same "which visit is this" invariant the appointment's
    # own relationships encode — a plain id join, no period on either side.
    #
    # A database FK could not be declared regardless: the appointment's
    # temporal primary key is (id, valid_at), so `id` alone backs no unique
    # index to reference.
  end

  actions do
    default_accept []
    defaults [:read]

    create :recognize do
      description "Recognize what a completed visit is owed."

      accept [:amount, :appointment_id, :recognized_at]
    end

    update :write_off do
      description "The charge will not be collected — waived, bad debt. It stays on the books as what it is."

      accept []

      change set_attribute(:status, :written_off)
    end
  end

  policies do
    policy action_type(:read) do
      description "The books are readable by anything that can reach the application."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only a signed-in member of staff may touch the books."
      authorize_if actor_present()
    end
  end
end
