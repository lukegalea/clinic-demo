defmodule ClinicDemo.Fhir.Patient do
  @moduledoc """
  A registered animal, in FHIR R4's `Patient` vocabulary. A façade over
  `ClinicDemo.Scheduling.Patient`: read-only, because registering and weighing
  an animal are scheduling's actions and keep their own policies.
  """

  use Ash.Resource,
    domain: ClinicDemo.Fhir,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true

    attribute :species, :atom,
      public?: true,
      constraints: [one_of: [:dog, :cat, :rabbit, :ferret, :bird, :reptile]]

    attribute :breed, :string, public?: true
    attribute :birth_date, :date, public?: true
    attribute :weight_kg, :decimal, public?: true
    attribute :identifier, :string, public?: true
  end

  facade do
    source ClinicDemo.Scheduling.Patient
    read_action :read

    map(:id, from: :id)
    map(:name, from: :name)
    map(:species, from: :species)
    map(:breed, from: :breed)
    map(:birth_date, from: :date_of_birth)
    map(:weight_kg, from: :weight_kg)
    map(:identifier, from: :microchip_number)

    hide(:owner_email, because: "The owner's contact is not part of the animal's resource.")
    hide(:inserted_at, because: "Row bookkeeping.")
    hide(:updated_at, because: "Row bookkeeping.")
  end
end
