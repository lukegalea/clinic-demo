defmodule ClinicDemo.Clm.ScheduledWork do
  @moduledoc """
  Work the contract schedules, such as a seasonal cleanup across its
  properties. The status is a stored value in the POC; in the platform it
  would come from the job the work raises.
  """

  use Ash.Resource,
    domain: ClinicDemo.Clm,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "clm_scheduled_work"
    repo ClinicDemo.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string, allow_nil?: false, public?: true
    attribute :scope, :string, public?: true
    attribute :due_on, :date, allow_nil?: false, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:upcoming, :overdue, :completed]
    end

    timestamps()
  end

  relationships do
    belongs_to :contract, ClinicDemo.Clm.Contract do
      allow_nil? false
      public? true
    end
  end

  actions do
    default_accept []

    defaults [:read]

    create :create do
      accept [:contract_id, :title, :scope, :due_on, :status]
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
