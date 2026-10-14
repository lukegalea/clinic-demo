defmodule ClinicDemo.Repo.Migrations.AddRevenueAndForecast do
  @moduledoc """
  The revenue/forecast model: the appointment type catalogue, the pointer
  from a visit to its catalogue entry, and the temporal `finance_charges`
  table.

  Hand-maintained rather than generated, per this repo's standing
  discipline: several of this schema's tables (ash_compliance_*, ash_events,
  scheduling_board_lanes) were created by hand-written migrations and have
  no committed snapshots, so every generator run re-emits their CREATE
  statements and the output needs the same pruning by hand. The three
  changes this migration actually makes are the three below.

  Invariants:

    * **Row ids are preserved.** The appointment change is a nullable
      column add; no row is rewritten, no id moves. The charges table is
      new, so there is no history to preserve — but it follows the
      appointments' temporal conventions from day one.
    * **`finance_charges` is temporal, shaped exactly like `appointments`.**
      A `valid_at` application-time period (tstzrange, `[inclusive,
      exclusive)`), filled by the extension from each write's `as_of`, and
      PostgreSQL 18's `PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)` — one
      row per charge valid at any instant, no two versions of one charge
      overlapping. (`btree_gist`, already installed, backs the exclusion.)
    * **No foreign key on `finance_charges.appointment_id` — on purpose.**
      The appointment's primary key is `(id, valid_at)`, so `id` alone
      backs no unique index to reference; the pointer is enforced in the
      application (the recognition hook) and joined plainly, like the
      appointment's own pointer relationships.
    * **`scheduling_appointment_types.name` is unique** — the catalogue is
      seeded lookup-or-create by name, so the database refuses a duplicate
      the same way a reseed would.
    * **The `appointments` pointer is nullable and unrestricted.** Visits
      predate the catalogue; a type row is restricted against deletion
      while any visit points at it.
  """

  use Ecto.Migration

  def up do
    # The price list.
    create table(:scheduling_appointment_types, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :base_price, :decimal, null: false
      add :default_duration_minutes, :bigint, null: false, default: 30

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:scheduling_appointment_types, [:name],
             name: "scheduling_appointment_types_unique_name_index"
           )

    # Which catalogue entry a visit is. Nullable: visits made before the
    # catalogue existed keep their NULL and recognize no charge.
    alter table(:appointments) do
      add :appointment_type_id, references(:scheduling_appointment_types, type: :uuid)
    end

    # The money. Same temporal shape as `appointments` — the extension
    # writes `valid_at` from each write's `as_of`, so every revenue read
    # can be pinned to an instant with `Ash.Query.as_of/2`.
    create table(:finance_charges, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()")
      add :appointment_id, :uuid, null: false
      add :amount, :decimal, null: false
      add :status, :text, null: false, default: "paid"
      add :recognized_at, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :valid_at, :tstzrange, null: false
    end

    execute("ALTER TABLE \"finance_charges\" ADD PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)")

    create index(:finance_charges, [:appointment_id])
  end

  def down do
    drop_if_exists index(:finance_charges, [:appointment_id])
    drop table(:finance_charges)

    alter table(:appointments) do
      remove :appointment_type_id
    end

    drop_if_exists unique_index(:scheduling_appointment_types, [:name],
                     name: "scheduling_appointment_types_unique_name_index"
                   )

    drop table(:scheduling_appointment_types)
  end
end
