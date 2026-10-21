defmodule ClinicDemo.Clm.ExtractedValue do
  @moduledoc """
  A value the AI read from the contract's signed document, waiting for a person
  to check it: the yellow fields of the design.

  `:confirm` accepts the value as read. `:correct` replaces it, and a person
  typing it counts as checking it, so it confirms too. The contract is
  verified when none is left unconfirmed (`Contract.verified?`).

  The value is display text with the page it came from. In the platform each
  one would also write through to the typed contract attribute it names
  (`field`); the POC stops at the check.
  """

  use Ash.Resource,
    domain: ClinicDemo.Clm,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table "clm_extracted_values"
    repo ClinicDemo.Repo
  end

  # The contract page's footer counts what is left to check, so it listens.
  pub_sub do
    module ClinicDemoWeb.Endpoint
    prefix "clm_extracted_values"
    publish_all :update, ["updated"]
  end

  attributes do
    uuid_primary_key :id

    attribute :section, :atom do
      description "Where the value belongs on the contract page."
      allow_nil? false
      public? true

      constraints one_of: [
                    :renewal_terms,
                    :contract_value,
                    :termination,
                    :insurance,
                    :indemnity,
                    :payment_terms
                  ]
    end

    attribute :field, :string do
      description "The contract attribute or clause this value is for, by name."
      allow_nil? false
      public? true
    end

    attribute :label, :string, allow_nil?: false, public?: true

    attribute :value, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500, trim?: true
    end

    attribute :page, :integer do
      description "The page of the source document the value was read from."
      public? true
      constraints min: 1
    end

    attribute :position, :integer, allow_nil?: false, default: 0, public?: true
    attribute :confirmed_at, :utc_datetime, public?: true

    timestamps()
  end

  relationships do
    belongs_to :contract, ClinicDemo.Clm.Contract do
      allow_nil? false
      public? true
    end
  end

  calculations do
    calculate :check_state, :atom, expr(if(is_nil(confirmed_at), :to_check, :confirmed)) do
      public? true
      constraints one_of: [:to_check, :confirmed]
    end

    calculate :source, :string, expr(if(is_nil(page), "", "p. " <> type(page, :string))) do
      public? true
    end
  end

  actions do
    default_accept []

    defaults [:read]

    create :create do
      accept [:contract_id, :section, :field, :label, :value, :page, :position]
    end

    update :confirm do
      description "Accept the value as the AI read it."
      accept []
      change set_attribute(:confirmed_at, &DateTime.utc_now/0)
    end

    update :correct do
      description "Replace the value with what the document says. Correcting it checks it."
      accept [:value]
      require_attributes [:value]
      change set_attribute(:confirmed_at, &DateTime.utc_now/0)
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
