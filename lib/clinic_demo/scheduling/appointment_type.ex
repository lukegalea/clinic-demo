defmodule ClinicDemo.Scheduling.AppointmentType do
  @moduledoc """
  The clinic's price list: what a kind of visit costs and how long it takes.

  A small seeded catalogue (`FinanceSeeds` lookup-or-creates by name),
  deliberately not temporal: a type's row is the
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

    attribute :mobile_capable, :boolean do
      description """
      Whether this kind of visit can be done at a client's address. A mobile-visit
      plan refuses a request for a type that is not (the plan is `needs_input`,
      naming the request), rather than driving somewhere to do what cannot be done
      there.
      """

      allow_nil? false
      public? true
      default false
    end

    attribute :mobile_equipment, {:array, :string} do
      description """
      What the veterinarian must carry for this visit away from the clinic
      (e.g. `"vaccine_cooler"`), compared with `Clinician.mobile_kit`. Empty when
      nothing special is needed.
      """

      allow_nil? false
      public? true
      default []
      constraints items: [min_length: 1, max_length: 40, trim?: true]
    end

    timestamps()
  end

  identities do
    identity :unique_name, [:name]
  end

  actions do
    default_accept [
      :name,
      :base_price,
      :default_duration_minutes,
      :mobile_capable,
      :mobile_equipment
    ]

    defaults [:read, :destroy, create: :*, update: :*]
  end
end
