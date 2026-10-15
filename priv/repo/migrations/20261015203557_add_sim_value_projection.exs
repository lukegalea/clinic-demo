defmodule ClinicDemo.Repo.Migrations.AddSimValueProjection do
  @moduledoc """
  BPSim BD-5's storage, in two parts:

    * `business_event_sim_value_projections` — the simulation value
      projection: one grain per (region, subject), one period per truth
      interval, `WITHOUT OVERLAPS`-keyed like the raw layer. A separate
      table on purpose (design risk #2): `drain_simulation` isolates the
      feed and the checkpoint, NOT the projection target — a sim drain
      through the real projector would write future-dated periods into
      the real value fold. Simulated futures land here and nowhere else.
    * the projector engine's internal tables (`ash_projection_checkpoints`,
      `ash_projection_dead_letter_events`, under the engine's configured
      table prefix) — the drain's cursors and its quarantine. Their shape
      is the `ash_events_projections` package's own, first landed in this
      app by this migration: sim checkpoints (`sim:<name>.<region>:<run>`)
      and real checkpoints share these rows, never each other's names.
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

    create table(:ash_projection_checkpoints, primary_key: false) do
      add :projection_name, :text, null: false, primary_key: true
      add :last_seen_event_id, :bigint
      add :events_processed, :bigint, null: false, default: 0

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:ash_projection_checkpoints, [:projection_name],
             name: "ash_projection_checkpoints_by_name_index"
           )

    create table(:ash_projection_dead_letter_events, primary_key: false) do
      add :projection_name, :text, null: false, primary_key: true
      add :event_id, :bigint, null: false, primary_key: true
      add :status, :text, null: false, default: "failed"
      add :error_class, :text, null: false
      add :error_message, :text, null: false
      add :stacktrace, :text
      add :failed_at, :utc_datetime_usec, null: false
      add :replayed_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:ash_projection_dead_letter_events, [:projection_name, :event_id],
             name: "ash_projection_dead_letter_events_by_projection_and_event_index"
           )
  end

  def down do
    drop_if_exists unique_index(
                     :ash_projection_dead_letter_events,
                     [:projection_name, :event_id],
                     name: "ash_projection_dead_letter_events_by_projection_and_event_index"
                   )

    drop table(:ash_projection_dead_letter_events)

    drop_if_exists unique_index(:ash_projection_checkpoints, [:projection_name],
                     name: "ash_projection_checkpoints_by_name_index"
                   )

    drop table(:ash_projection_checkpoints)

    execute(
      "ALTER TABLE \"business_event_sim_value_projections\" DROP CONSTRAINT IF EXISTS \"business_event_sim_value_projections_by_grain_index\""
    )

    drop table(:business_event_sim_value_projections)
  end
end
