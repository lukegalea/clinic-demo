defmodule ClinicDemo.Fhir.Practitioner do
  @moduledoc """
  A member of staff, in FHIR R4's `Practitioner` vocabulary. A façade over
  `ClinicDemo.Scheduling.Clinician`; read-only.
  """

  use Ash.Resource,
    domain: ClinicDemo.Fhir,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true

    attribute :qualification, :atom,
      public?: true,
      constraints: [one_of: [:veterinarian, :technician, :nurse]]

    attribute :identifier, :string, public?: true
    attribute :active, :boolean, public?: true
  end

  facade do
    source ClinicDemo.Scheduling.Clinician
    read_action :read

    map(:id, from: :id)
    map(:name, from: :full_name)
    map(:qualification, from: :role)
    map(:identifier, from: :license_number)
    map(:active, from: :active)

    hide(:leadership,
      because: "A position of authority in the roster's approval, not a qualification."
    )

    hide(:mobile_kit, because: "Equipment carried on mobile visits is an operational detail.")
    hide(:inserted_at, because: "Row bookkeeping.")
    hide(:updated_at, because: "Row bookkeeping.")
  end
end
