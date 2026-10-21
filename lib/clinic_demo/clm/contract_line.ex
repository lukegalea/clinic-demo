defmodule ClinicDemo.Clm.ContractLine do
  @moduledoc """
  One priced line of a contract: a service at a property, for a period.

  The property is a name and address here; in the platform it is the
  property resource.
  """

  use Ash.Resource,
    domain: ClinicDemo.Clm,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "clm_contract_lines"
    repo ClinicDemo.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :property_name, :string, allow_nil?: false, public?: true
    attribute :property_address, :string, public?: true
    attribute :service, :string, allow_nil?: false, public?: true
    attribute :starts_on, :date, allow_nil?: false, public?: true
    attribute :ends_on, :date, allow_nil?: false, public?: true

    attribute :amount, :decimal do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :cadence, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:month, :season, :year, :visit]
    end

    timestamps()
  end

  relationships do
    belongs_to :contract, ClinicDemo.Clm.Contract do
      allow_nil? false
      public? true
    end
  end

  calculations do
    calculate :price,
              :string,
              expr("$" <> type(amount, :string) <> " / " <> type(cadence, :string)) do
      public? true
    end
  end

  actions do
    default_accept []
    defaults [:read]

    create :create do
      accept [
        :contract_id,
        :property_name,
        :property_address,
        :service,
        :starts_on,
        :ends_on,
        :amount,
        :cadence
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_present()
    end
  end
end
