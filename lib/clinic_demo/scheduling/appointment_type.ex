defmodule ClinicDemo.Scheduling.AppointmentType do
  @moduledoc """
  The clinic's price list: what a kind of visit costs and how long it takes.

  A small seeded catalogue (`FinanceSeeds` lookup-or-creates by name, the way
  `BoardLane` is seeded), deliberately not temporal: a type's row is the
  catalogue's *present* answer, and the charge a completed visit recognizes
  snapshots the amount at completion (`Finance.Charge.amount`) rather than
  pointing at a moving number. Revenue history therefore survives repricing
  the catalogue — the snapshot is the record.

  `Appointment.appointment_type` is nullable: bookings made before the
  catalogue existed (and every manually booked visit that skips it) simply
  recognize no charge.
  """

  use Ash.Resource, domain: ClinicDemo.Scheduling, data_layer: AshPostgres.DataLayer

  postgres do
    table "scheduling_appointment_types"
    repo ClinicDemo.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      description "The catalogue entry, as the front desk says it. Unique."
      allow_nil? false
      public? true
      constraints max_length: 80, trim?: true
    end

    attribute :base_price, :decimal do
      description """
      What the visit recognizes when it completes. Never a float — a price
      lives in `Decimal` or it does not live at all.
      """

      allow_nil? false
      public? true
      constraints min: 0, max: 100_000
    end

    attribute :default_duration_minutes, :integer do
      description "The slot length a booking of this type defaults to, in five-minute increments."
      allow_nil? false
      public? true
      default 30
      constraints min: 5, max: 240
    end

    timestamps()
  end

  identities do
    identity :unique_name, [:name]
  end

  actions do
    default_accept [:name, :base_price, :default_duration_minutes]
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
