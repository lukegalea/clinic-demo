defmodule ClinicDemo.BusinessEvents.SimValueProjection do
  @moduledoc """
  The value projection of SIMULATED futures (BPSim BD-5) — and the reason
  it is a separate table at all (design risk #2): `drain_simulation`
  isolates the *feed and checkpoint*, not the projection target. A sim
  drain through a real projector would write future-dated periods into
  the real projection, where any `as_of(future_T)` read — or a real
  rebuild — would fold fabricated completions into the clinic's actual
  revenue. The package leaves the target to the host; this resource is
  the host's answer: a temporal projection with the exact shape of the
  real value fold, but its own table, reachable only through
  `ClinicDemo.BusinessEvents.SimValueProjector.drain_simulation/2`.

  Isolation is structural, three ways:

    * **Table** — a sim period lives here; no real projector targets
      this table, and no read of the real projection can see one.
    * **Shape** — every twin event that feeds it carries `simulated:
      true` and a `simulation_run` label set at record time; the
      supported surface for run listings is
      `AshDiscreteBusinessEvents.simulation_runs/1`.
    * **Cursor** — sim drains checkpoint `sim:sim_value_projection_v1.<region>:<run>`;
      no real drain's cursor can alias one, and two runs never share.

  Same grain and field set as the design's §2c value projection — the
  fold handlers are the scenario fold's own,
  `ClinicDemo.BusinessEvents.VisitProjectionOps` — so a scenario overlay
  reads this table the same way the real page reads its own. All periods
  here are future-dated by construction: the generator only fabricates
  visits still ahead of us.
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

      description "The grain's region — projections never merge regions."
    end

    attribute :subject, :string do
      allow_nil? false
      public? true
      constraints max_length: 512

      description "The visit's id — the ledger's record_id, the sim fold's grain."
    end

    attribute :outcome, :atom do
      public? true
      constraints one_of: [:open, :completed, :cancelled, :no_show]

      description "The visit's state as of the period, as the sim drew it."
    end

    attribute :urgency, :string do
      public? true

      description "The triage decision as of the period (absent on scenario rows — simulations draw outcomes, not decisions)."
    end

    attribute :urgency_band, :string do
      public? true
      description "The mapping's decoded band for the triage urgency."
    end

    attribute :expected_amount, :decimal do
      public? true
      description "The catalogue price booked — value as expectation."
    end

    attribute :recognized_amount, :decimal do
      public? true
      description "The amount the drawn completion would recognize."
    end

    attribute :recognized_at, :utc_datetime_usec do
      public? true
      description "The drawn completion's truth instant."
    end

    attribute :written_off_amount, :decimal do
      public? true
      description "Written-off money as of the period."
    end

    attribute :scheduled_at, :utc_datetime do
      public? true
      description "The visit's slot as of the period."
    end

    attribute :corrections, :integer do
      allow_nil? false
      default 0
      public? true

      description "How many superseding events have restated this subject so far — corrections are events."
    end

    # No create/update timestamps: the temporal machinery owns the wall
    # clock here — `recorded_at` is the write's stamp, `valid_at` the
    # period. Same posture as the raw layer and the package's own
    # PipelineHistory fixture.
  end

  postgres do
    table "business_event_sim_value_projections"
    repo ClinicDemo.Repo
  end

  actions do
    # The as-of surface: strategy :context makes plain reads the CURRENT
    # version of every grain; `Ash.Query.as_of/2` pins any instant —
    # "what the scenario says the clinic earns at future T". Every
    # period here lives in the future, so a current read is empty by
    # construction — the sim never leaks into the present.
    read :read do
      primary? true
    end
  end
end
