defmodule ClinicDemo.Repo.Migrations.TemporalizeAppointments do
  @moduledoc """
  Temporalizes `appointments`: adds the `valid_at` application-time period
  and swaps the primary key to PostgreSQL 18's `PRIMARY KEY (id, valid_at
  WITHOUT OVERLAPS)`.

  Hand-maintained rather than generated, per the temporal migration
  discipline: the schema had no 2.14-format snapshot baseline for a clean
  generator diff, and the invariants below are worth stating where the SQL
  is.

  Invariants:

    * **Row ids are preserved.** The primary-key swap keeps `id` as the
      leading key — a record is still the same record across all of its
      versions; only the period distinguishes them. No id churn, ever: an
      id is the audit log's `record_id` join key.
    * **In-place backfill, no rewrite of identity.** Every row that exists
      at migration time is the version still valid now, so its period is
      `[inserted_at, ∞)`. `inserted_at` is a naive UTC timestamp, so the
      `AT TIME ZONE 'UTC'` conversion names the zone explicitly rather than
      leaning on the session's.
    * **The audit log is untouched.** `ash_events` rows reference
      appointments by `record_id` (= `id`), which does not change.
    * **The foreign keys stay.** With one temporal side the relationships
      are logical-only upstream (no `PERIOD` foreign key is possible), but a
      plain FK on the id pointer remains sound — every version row points at
      the same patient and clinician — and the demo's integrity semantics
      (`on_delete: :delete` for patients, `:restrict` for clinicians) ride
      on those constraints. This migration neither drops nor recreates them.

  Down: removes the period and restores the plain primary key. Only sound
  on a table whose history has not been used — a table with split versions
  has several rows per id and the restored unique key would refuse them.
  """

  use Ecto.Migration

  def up do
    # The period column, nullable until the backfill lands.
    execute("ALTER TABLE appointments ADD COLUMN valid_at tstzrange")

    # In-place backfill: existing rows are the current versions.
    execute("""
    UPDATE appointments
       SET valid_at = tstzrange(inserted_at AT TIME ZONE 'UTC', NULL)
    """)

    execute("ALTER TABLE appointments ALTER COLUMN valid_at SET NOT NULL")

    # The temporal primary key. `WITHOUT OVERLAPS` is a GiST exclusion under
    # the hood (hence the repo's `btree_gist`): one row per appointment may
    # be valid at any instant, and no two versions of one appointment may
    # overlap in time.
    execute("ALTER TABLE appointments DROP CONSTRAINT appointments_pkey")

    execute("""
    ALTER TABLE appointments
      ADD PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)
    """)
  end

  def down do
    execute("ALTER TABLE appointments DROP CONSTRAINT appointments_pkey")
    execute("ALTER TABLE appointments ADD PRIMARY KEY (id)")

    # Collapses history: any appointment whose versions were split by a
    # temporal write has several rows sharing one id, and the restored
    # unique key refuses them. That refusal is the honest shape of rolling
    # back temporalization.
    execute("ALTER TABLE appointments DROP COLUMN valid_at")
  end
end
