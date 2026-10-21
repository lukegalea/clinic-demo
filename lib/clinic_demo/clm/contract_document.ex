defmodule ClinicDemo.Clm.ContractDocument do
  @moduledoc """
  A file on a contract: the signed agreement and any amendment or rider, in
  version order. The POC keeps the file name only; no file is stored.
  """

  use Ash.Resource,
    domain: ClinicDemo.Clm,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "clm_contract_documents"
    repo ClinicDemo.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :version, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:signed_agreement, :amendment, :rider]
    end

    attribute :filename, :string, allow_nil?: false, public?: true
    attribute :uploaded_on, :date, allow_nil?: false, public?: true

    timestamps()
  end

  relationships do
    belongs_to :contract, ClinicDemo.Clm.Contract do
      allow_nil? false
      public? true
    end
  end

  calculations do
    calculate :version_label, :string, expr("v" <> type(version, :string)) do
      public? true
    end
  end

  actions do
    default_accept []

    defaults [:read]

    create :create do
      accept [:contract_id, :version, :kind, :filename, :uploaded_on]
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
