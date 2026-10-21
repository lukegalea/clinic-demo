defmodule ClinicDemoWeb.A2ui.ContractUI do
  @moduledoc """
  CLM 2.0 POC: the contract page (claude.ai design "Contract Page"), declared.

  The surface's own resource is `ExtractedValue`, because checking what the AI
  read is the page's one job and the only place it writes: a related table is
  read-only by construction, so the writable table has to be the surface's own.
  Everything else hangs off the `:contract` context:

    * the route picks the contract (`/contracts/:id`); the hub links here;
    * the four detail cards are the design's Details, Parties, Renewal terms and
      Contract value;
    * Properties & pricing, Scheduled work and Document versions are related
      tables, read-only, read under each resource's own policies.

  What the declaration cannot say yet, and `ContractLive` draws in HEEx around
  the surface: the header with its badges, the lifecycle bar, the section
  nav and the sticky "N to check" footer. Inline per-field editing (the
  design's yellow inputs with a check button) has no A2UI vocabulary; the
  checking is the To check table's Confirm and Correct row actions instead.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Clm.ExtractedValue
    surface_id "clm_contract"
    title "Contract"
    record_label("value")
    spec_version "0.9.1"

    # Set by the route (`/contracts/:id`, see `ContractLive`), through the
    # same authorized read as any context selection. Never picked here.
    context :contract do
      resource ClinicDemo.Clm.Contract
      option_label :name
      picker false
    end

    component :detail, :details do
      context :contract
      fields [:name, :intake_label, :template_name, :deal_origin_label, :recorded_on]
    end

    component :detail, :parties do
      context :contract
      fields [:vendor_name, :pmc_name, :property_manager_name, :enterprise_leader_name]
    end

    component :detail, :renewal_terms do
      context :contract

      fields [
        :expires_on,
        :notice_period_days,
        :notice_deadline,
        :renewal_mode_label,
        :reminder_lead_days,
        :expiring_soon_on
      ]
    end

    component :detail, :contract_value do
      context :contract
      fields [:total_value_text, :annual_value_text]
    end

    # The design's yellow fields and clauses: one row per extracted value,
    # grouped by where it belongs on the page.
    component :table, :to_check do
      fields [:label, :value, :source, :check_state]
      read_action :read
      query :to_check
      context_filter contract_id: :contract
      require_context [:contract]
      row_actions [:confirm, :correct]
      bulk_actions [:confirm]

      sections do
        scope_by :section

        values [
          :renewal_terms,
          :contract_value,
          :termination,
          :insurance,
          :indemnity,
          :payment_terms
        ]

        labels renewal_terms: "Renewal terms",
               contract_value: "Contract value",
               termination: "Termination",
               insurance: "Insurance",
               indemnity: "Indemnity",
               payment_terms: "Payment terms"
      end
    end

    component :table, :lines do
      resource ClinicDemo.Clm.ContractLine
      fields [:property_name, :property_address, :service, :starts_on, :ends_on, :price]
      read_action :read
      query :lines
      context_filter contract_id: :contract
      require_context [:contract]
    end

    component :table, :scheduled_work do
      resource ClinicDemo.Clm.ScheduledWork
      fields [:title, :scope, :due_on, :status]
      read_action :read
      query :scheduled_work
      context_filter contract_id: :contract
      require_context [:contract]
    end

    component :table, :documents do
      resource ClinicDemo.Clm.ContractDocument
      fields [:version_label, :kind, :filename, :uploaded_on]
      read_action :read
      query :documents
      context_filter contract_id: :contract
      require_context [:contract]
    end

    query :to_check do
      sortable [:position]
      default_sort position: :asc
      page_size 50
    end

    query :lines do
      sortable [:property_name]
      default_sort property_name: :asc
      page_size 50
    end

    query :scheduled_work do
      sortable [:due_on]
      default_sort due_on: :asc
    end

    query :documents do
      sortable [:version]
      default_sort version: :desc
    end

    action :confirm do
      label "Confirm"
      visible_when check_state: :to_check
      refreshes [:to_check]
    end

    action :correct do
      label "Correct"
      prompt_fields [:value]
      prompt_title "Correct the extracted value"
      refreshes [:to_check]
    end

    # Labels by field name, across the surface's resources.
    field :name do
      label "Contract name"
    end

    field :pmc_name do
      label "Property management company"
    end

    field :property_manager_name do
      label "Property manager"
    end

    field :enterprise_leader_name do
      label "Enterprise leader"
    end

    field :intake_label do
      label "How it entered VendorPM"
    end

    field :template_name do
      label "Template used"
    end

    field :deal_origin_label do
      label "Where the deal came from"
    end

    field :recorded_on do
      label "Recorded"
      format :date
    end

    field :expires_on do
      label "Expiry date"
      format :date
    end

    field :notice_period_days do
      label "Notice period (days)"
    end

    field :notice_deadline do
      label "Notice deadline"
      format :date
    end

    field :renewal_mode_label do
      label "Renewal mode"
    end

    field :reminder_lead_days do
      label "Reminder lead time (days)"
    end

    field :expiring_soon_on do
      label "Becomes Expiring soon"
      format :date
    end

    field :total_value_text do
      label "Total value"
    end

    field :annual_value_text do
      label "Annual value"
    end

    field :source do
      label "Source"
    end

    field :check_state do
      label "Check"
    end

    field :property_name do
      label "Property"
    end

    field :property_address do
      label "Address"
    end

    field :starts_on do
      label "From"
      format :date
    end

    field :ends_on do
      label "To"
      format :date
    end

    field :due_on do
      label "Due"
      format :date
    end

    field :version_label do
      label "Version"
    end

    field :filename do
      label "File"
    end

    field :uploaded_on do
      label "Uploaded"
      format :date
    end
  end
end
