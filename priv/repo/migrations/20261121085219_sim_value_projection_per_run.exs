defmodule ClinicDemo.Repo.Migrations.SimValueProjectionPerRun do
  @moduledoc """
  The simulation value projection's grain gains the run: one row per
  (region, subject, simulation_run) instead of one per (region, subject),
  so two runs that draw the same visit write two rows.

  The table is derived data: every row is folded from the simulation twin.
  The generated migration added `simulation_run` as NOT NULL to a table
  that may hold rows with no run, and tried to drop the old grain
  constraint as an index (it is an exclusion constraint). This one empties
  the table and removes the sim projector's checkpoints, so the next
  `drain_simulation/2` of each run re-folds it from the twin into per-run
  rows; the twin is untouched.
  """

  use Ecto.Migration

  def up do
    execute(
      "DELETE FROM ash_projection_checkpoints WHERE projection_name LIKE 'sim:sim_value_projection_v1.%'"
    )

    execute("DELETE FROM business_event_sim_value_projections")

    execute(
      "ALTER TABLE \"business_event_sim_value_projections\" DROP CONSTRAINT \"business_event_sim_value_projections_by_grain_index\""
    )

    alter table(:business_event_sim_value_projections) do
      add :simulation_run, :text, null: false
    end

    execute(
      "ALTER TABLE \"business_event_sim_value_projections\" ADD CONSTRAINT \"business_event_sim_value_projections_by_grain_index\" EXCLUDE USING gist (region WITH =, subject WITH =, simulation_run WITH =, valid_at WITH &&)"
    )
  end

  def down do
    execute(
      "DELETE FROM ash_projection_checkpoints WHERE projection_name LIKE 'sim:sim_value_projection_v1.%'"
    )

    execute("DELETE FROM business_event_sim_value_projections")

    execute(
      "ALTER TABLE \"business_event_sim_value_projections\" DROP CONSTRAINT \"business_event_sim_value_projections_by_grain_index\""
    )

    alter table(:business_event_sim_value_projections) do
      remove :simulation_run
    end

    execute(
      "ALTER TABLE \"business_event_sim_value_projections\" ADD CONSTRAINT \"business_event_sim_value_projections_by_grain_index\" EXCLUDE USING gist (region WITH =, subject WITH =, valid_at WITH &&)"
    )
  end
end
