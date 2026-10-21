defmodule ClinicDemoWeb.A2ui.ContractsHubUI do
  @moduledoc """
  CLM 2.0 POC: the Contracts Hub (claude.ai design "Contracts Hub"), declared.

  One table of contracts with search and the design's filters that map onto
  the model (status, verification, vendor). Each name links to the contract
  page. The stat cards above it are the HEEx shell's (`ContractsHubLive`):
  they are links that set this table's filter through the URL.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Clm.Contract
    surface_id "clm_contracts_hub"
    title "Contracts"
    record_label("contract")
    spec_version "0.9.1"

    query :default do
      search_fields [:name, :vendor_name]
      sortable [:name, :expires_on, :notice_deadline]
      filters [:status, :verified?, :vendor_name]
      default_sort expires_on: :asc
      page_size 20
    end

    component :table, :contracts do
      fields [
        :name,
        :vendor_name,
        :property_summary,
        :service_summary,
        :status,
        :notice_deadline,
        :expires_on,
        :verification
      ]

      read_action :read
      query :default

      # The design's coloured status tags: the admin grid draws the badge
      # field as a tag column, toned by `badge_tones`.
      row_layout do
        title :name
        badge :status
        badge_text active: "Active", expiring_soon: "Expiring soon", expired: "Expired"
        badge_tones active: :info, expiring_soon: :warning, expired: :neutral

        meta [
          :vendor_name,
          :property_summary,
          :service_summary,
          :notice_deadline,
          :expires_on,
          :verification
        ]
      end
    end

    field :name do
      label "Contract"
      link {:contract, :id}
    end

    field :vendor_name do
      label "Vendor"
    end

    field :property_summary do
      label "Property"
    end

    field :service_summary do
      label "Service"
    end

    field :status do
      label "Status"
    end

    field :verified? do
      label "Verified"
    end

    field :notice_deadline do
      label "Notice deadline"
      format :date
    end

    field :expires_on do
      label "Expires"
      format :date
    end

    field :verification do
      label "Verification"
    end
  end
end
