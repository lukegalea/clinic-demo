defmodule ClinicDemo.BusinessEvents.ValueProjection do
  @moduledoc """
  The clinic's value projection (BPSim BD-3): one temporal row per visit —
  grain `[:region, :subject]` — folded from the ledger by
  `ClinicDemo.BusinessEvents.ValueProjector`.

  The design's grain ruling, concrete: per-appointment is the BIZEV-native
  shape, preserves drill-down (a month bar can later link to its
  appointments), and feeds both halves of `/revenue` from one fold — the
  recognized-by-month chart and the completion-rate table are reads over
  these rows. Month/week grouping happens in Elixir at read time, the
  exact posture `Finance.revenue_by_month/1` already takes.

  The resource is **temporal** (`strategy :context`) — the projector's
  writes run `as_of event.occurred_at` (the drain's ruling on temporal
  targets), so a visit's truth history is one period per interval: booked
  (expected value) → triaged (weight) → completed / cancelled / no_show
  (outcome). "What did this visit look like at T" is the plain containment
  read, `Ash.Query.as_of/2` — the same grammar the board and the charges
  speak.

  Fields are the design's: the outcome lattice, the triage weight, the
  three money moments (expected, recognized, written-off), and the
  forecast's dimensions (`type_id`, `clinician_id`, `scheduled_at`).
  `corrections` is the engine's convention counter — this demo records no
  superseding events yet, so it stays zero; the column is the slot the
  corrections machinery fills the day the clinic restates a value.
  """

  use Ash.Resource,
    domain: ClinicDemo.BusinessEvents,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Projections.ProjectionResource]

  temporal do
    strategy :context
    attribute :valid_at
    recorded_at :recorded_at
  end

  projection_resource do
    grain_fields([:region, :subject])
  end

  attributes do
    uuid_primary_key :id

    attribute :region, :atom do
      allow_nil? false
      public? true

      description "The grain's region — projections never merge regions (the ledger's §6 discipline, carried)."
    end

    attribute :subject, :string do
      allow_nil? false
      public? true
      constraints max_length: 512

      description "The visit's appointment id — the ledger's record_id, the grain's subject."
    end

    attribute :outcome, :atom do
      public? true
      default :open
      constraints one_of: [:open, :completed, :cancelled, :no_show]

      description "Where the visit stands as of the period — open until a terminal event lands."
    end

    attribute :urgency, :string do
      public? true
      description "The triage decision's answer as of the period."
    end

    attribute :urgency_band, :string do
      public? true
      description "The decision's weight — the mapping's decode of the urgency."
    end

    attribute :expected_amount, :decimal do
      public? true

      description "The catalogue price at booking, as of the period. Nil for a pre-catalogue visit."
    end

    attribute :recognized_amount, :decimal do
      public? true

      description "What the write-up recognized, as of the period. Nil until completed-with-a-type."
    end

    attribute :recognized_at, :utc_datetime_usec do
      public? true
      description "When the recognition took effect — the completion's own instant."
    end

    attribute :written_off_amount, :decimal do
      public? true

      description "Money this visit's charge will not collect — a value revision, recorded as its own event."
    end

    attribute :type_id, :uuid do
      public? true

      description "The catalogue entry — a forecast dimension (absent-path for pre-catalogue visits)."
    end

    attribute :clinician_id, :uuid do
      public? true
      description "Who the visit was booked with — a forecast dimension."
    end

    attribute :scheduled_at, :utc_datetime do
      public? true
      description "The booked slot — the weekday's source in the rates table."
    end

    attribute :corrections, :integer do
      allow_nil? false
      default 0
      public? true

      description """
      How many superseding events have restated this visit so far — the
      engine's convention. The clinic records no supersedes yet; the slot
      is the corrections machinery's.
      """
    end

    # No create/update timestamps: the temporal machinery owns the wall
    # clock here — `recorded_at` is the write's stamp, `valid_at` validity.
  end

  postgres do
    table "value_projections"
    repo ClinicDemo.Repo
  end

  actions do
    read :read do
      primary? true

      description "Every visit as of now — with strategy :context, the current version of every grain."
    end
  end

  # No policies: the projection's only writer is the drain (which runs
  # `authorize?: false`, the machinery's own posture) and its reads are
  # the application's `authorize?: false` reads — derived, rebuildable
  # data with exactly one writer.
end
