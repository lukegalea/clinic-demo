defmodule ClinicDemo.Clm.Contract do
  @moduledoc """
  A contract between a property management company and a vendor, covering one
  or more properties and services.

  The parties are plain names here: in the platform they are the PMC, PM,
  enterprise leader and vendor resources, and this POC only needs to show
  them. Dates and money are real attributes, because the lifecycle (notice
  deadline, expiring soon, annual value) is derived from them.
  """

  use Ash.Resource,
    domain: ClinicDemo.Clm,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "clm_contracts"
    repo ClinicDemo.Repo
  end

  # A contract enters the "Expiring soon" stage this many days before it
  # expires. The design's dates (Aug 3 for a Dec 31 expiry) imply 150.
  @expiring_soon_days 150

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 160, trim?: true
    end

    attribute :vendor_name, :string, allow_nil?: false, public?: true
    attribute :pmc_name, :string, allow_nil?: false, public?: true
    attribute :property_manager_name, :string, public?: true
    attribute :enterprise_leader_name, :string, public?: true

    attribute :intake, :atom do
      description "How the contract entered the platform."
      allow_nil? false
      public? true
      constraints one_of: [:uploaded_paper, :signed_on_platform]
    end

    attribute :template_name, :string do
      description "Nil for uploaded paper: no template was used."
      public? true
    end

    attribute :deal_origin, :atom do
      description "Where the deal came from."
      public? true
      constraints one_of: [:off_platform_quote, :rfq_award]
    end

    attribute :recorded_on, :date, public?: true
    attribute :starts_on, :date, allow_nil?: false, public?: true
    attribute :expires_on, :date, allow_nil?: false, public?: true

    attribute :notice_period_days, :integer do
      public? true
      constraints min: 0
    end

    attribute :renewal_mode, :atom do
      public? true
      constraints one_of: [:auto_extend, :renew_on_request, :ends_on_expiry]
    end

    attribute :reminder_lead_days, :integer do
      description "Nil until someone sets a reminder."
      public? true
      constraints min: 0
    end

    attribute :total_value, :decimal do
      public? true
      constraints min: 0
    end

    timestamps()
  end

  relationships do
    has_many :lines, ClinicDemo.Clm.ContractLine, public?: true
    has_many :extracted_values, ClinicDemo.Clm.ExtractedValue, public?: true
    has_many :scheduled_work, ClinicDemo.Clm.ScheduledWork, public?: true
    has_many :documents, ClinicDemo.Clm.ContractDocument, public?: true
  end

  aggregates do
    count :to_check_count, :extracted_values do
      description "Extracted values no person has confirmed yet."
      filter expr(is_nil(confirmed_at))
      public? true
    end

    count :property_count, :lines do
      field :property_name
      uniq? true
      public? true
    end

    count :service_count, :lines do
      field :service
      uniq? true
      public? true
    end
  end

  calculations do
    calculate :verified?, :boolean, expr(to_check_count == 0) do
      public? true
    end

    calculate :verification, :string, expr(if(to_check_count == 0, "Verified", "Unverified")) do
      public? true
    end

    # Where the contract is in its term, today. Expression-based so the hub
    # can filter on it.
    calculate :status,
              :atom,
              expr(
                cond do
                  expires_on < today() -> :expired
                  date_add(expires_on, -@expiring_soon_days, :day) <= today() -> :expiring_soon
                  true -> :active
                end
              ) do
      public? true
      constraints one_of: [:active, :expiring_soon, :expired]
    end

    calculate :property_summary,
              :string,
              {ClinicDemo.Clm.Calculations.Summary, field: :property_name} do
      description "The first property, and how many more (\"Harbourfront Tower +3 more\")."
      public? true
    end

    calculate :service_summary, :string, {ClinicDemo.Clm.Calculations.Summary, field: :service} do
      public? true
    end

    calculate :notice_deadline,
              :date,
              expr(
                if is_nil(notice_period_days) do
                  nil
                else
                  date_add(expires_on, -notice_period_days, :day)
                end
              ) do
      description "The last day notice can be given to stop the renewal."
      public? true
    end

    calculate :expiring_soon_on, :date, expr(date_add(expires_on, -@expiring_soon_days, :day)) do
      public? true
    end

    calculate :annual_value, :decimal, ClinicDemo.Clm.Calculations.AnnualValue do
      public? true
    end

    # Display text for the surface: ash_a2ui formats dates only, so enum
    # labels and money are written here, once, in English.
    calculate :intake_label,
              :string,
              expr(
                cond do
                  intake == :uploaded_paper -> "Uploaded paper"
                  intake == :signed_on_platform -> "Signed in VendorPM"
                  true -> nil
                end
              ) do
      public? true
    end

    calculate :deal_origin_label,
              :string,
              expr(
                cond do
                  deal_origin == :off_platform_quote -> "Off-platform quote"
                  deal_origin == :rfq_award -> "RFQ award"
                  true -> nil
                end
              ) do
      public? true
    end

    calculate :renewal_mode_label,
              :string,
              expr(
                cond do
                  renewal_mode == :auto_extend -> "Auto-extend"
                  renewal_mode == :renew_on_request -> "Renews on request"
                  renewal_mode == :ends_on_expiry -> "Ends on expiry"
                  true -> nil
                end
              ) do
      public? true
    end

    calculate :total_value_text,
              :string,
              {ClinicDemo.Clm.Calculations.Money, field: :total_value} do
      public? true
    end

    calculate :annual_value_text,
              :string,
              {ClinicDemo.Clm.Calculations.Money, field: :annual_value} do
      public? true
    end
  end

  actions do
    default_accept []
    defaults [:read]

    create :record do
      description "Record a contract, typically from an uploaded signed document."

      accept [
        :name,
        :vendor_name,
        :pmc_name,
        :property_manager_name,
        :enterprise_leader_name,
        :intake,
        :template_name,
        :deal_origin,
        :recorded_on,
        :starts_on,
        :expires_on,
        :notice_period_days,
        :renewal_mode,
        :reminder_lead_days,
        :total_value
      ]

      validate compare(:expires_on, greater_than: :starts_on) do
        message "must be after the start date"
      end
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
