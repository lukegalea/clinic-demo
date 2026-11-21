defmodule ClinicDemo.Fhir.Location do
  @moduledoc """
  A place a visit happens, in FHIR R4's `Location` vocabulary. A façade over
  `ClinicDemo.Scheduling.ServiceLocation`; read-only.
  """

  use Ash.Resource,
    domain: ClinicDemo.Fhir,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
    attribute :type, :atom, public?: true, constraints: [one_of: [:clinic, :client_site]]
    attribute :address_line, :string, public?: true
    attribute :city, :string, public?: true
    attribute :postal_code, :string, public?: true
    attribute :latitude, :decimal, public?: true
    attribute :longitude, :decimal, public?: true
    attribute :active, :boolean, public?: true
  end

  facade do
    source ClinicDemo.Scheduling.ServiceLocation
    read_action :read

    map(:id, from: :id)
    map(:name, from: :name)
    map(:type, from: :kind)
    map(:address_line, from: :address_line)
    map(:city, from: :city)
    map(:postal_code, from: :postal_code)
    map(:latitude, from: :latitude)
    map(:longitude, from: :longitude)
    map(:active, from: :active)

    hide(:access_constraints,
      because: "Site access notes are a planning input, not part of the place."
    )

    hide(:access_buffer_minutes,
      because: "Travel buffering is a planning input, not part of the place."
    )

    hide(:inserted_at, because: "Row bookkeeping.")
    hide(:updated_at, because: "Row bookkeeping.")
  end
end
