defmodule ClinicDemo.Repo.Migrations.AddSimValueProjection do
  @moduledoc """
  BPSim BD-5's storage: `business_event_sim_value_projections` — the
  simulation value projection: one grain per (region, subject), one
  period per truth interval, `WITHOUT OVERLAPS`-keyed like the raw
  layer. A separate table on purpose (design risk #2): `drain_simulation`
  isolates the feed and the checkpoint, NOT the projection target — a
  sim drain through the real projector would write future-dated periods
  into the real value fold. Simulated futures land here and nowhere
  else.

  The projector engine's internal tables (checkpoints, dead letters —
  the drain's cursors and quarantine) are BD-3's migration's; sim
  checkpoints (`sim:<name>.<region>:<run>`) and real checkpoints share
  those rows, never each other's names.
  """

  use Ecto.Migration

  def up do
    create table(:business_event_sim_value_projections, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()")
      add :region, :text, null: false
      add :subject, :text, null: false
      add :outcome, :text
      add :urgency, :text
      add :urgency_band, :text
      add :expected_amount, :decimal
      add :recognized_amount, :decimal
      add :recognized_at, :utc_datetime_usec
      add :written_off_amount, :decimal
      add :scheduled_at, :utc_datetime
      add :corrections, :bigint, null: false, default: 0

      add :valid_at, :tstzrange, null: false

      add :recorded_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    execute(
      "ALTER TABLE \"business_event_sim_value_projections\" ADD PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)"
    )

    execute(
      "ALTER TABLE \"business_event_sim_value_projections\" ADD CONSTRAINT \"business_event_sim_value_projections_by_grain_index\" EXCLUDE USING gist (region WITH =, subject WITH =, valid_at WITH &&)"
    )
  end

  def down do
    execute(
      "ALTER TABLE \"business_event_sim_value_projections\" DROP CONSTRAINT IF EXISTS \"business_event_sim_value_projections_by_grain_index\""
    )

    drop table(:business_event_sim_value_projections)
  end
end
