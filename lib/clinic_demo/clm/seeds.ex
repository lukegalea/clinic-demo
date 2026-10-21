defmodule ClinicDemo.Clm.Seeds do
  @moduledoc """
  Invented contracts for the CLM POC, shaped like the CLM 2.0 contract-page
  design. No customer or vendor record is used.

  Idempotent by contract name: `mix run -e "ClinicDemo.Clm.Seeds.run()"`.
  """

  alias ClinicDemo.Clm.{Contract, ContractDocument, ContractLine, ExtractedValue, ScheduledWork}

  @properties [
    {"Harbourfront Tower", "200 Queens Quay W, Toronto, ON M5J 2Y5"},
    {"Maple Court", "45 Maple Ave, Toronto, ON M4W 2T7"},
    {"King West Lofts", "560 King St W, Toronto, ON M5V 1M3"},
    {"Riverside Commons", "1280 Riverside Dr, Ottawa, ON K1G 3T7"}
  ]

  @addresses %{
    "Bayview Gardens" => "15 Bayview Ave, Toronto, ON M4G 3B6",
    "Queensway Plaza" => "880 The Queensway, Toronto, ON M8Z 1N5",
    "Lakeshore Terrace" => "2100 Lake Shore Blvd W, Toronto, ON M8V 4C7",
    "Elm Park Residences" => "33 Elm Park Ave, Ottawa, ON K1Y 2K3"
  }

  # {name, vendor, properties, services, starts_on, expires_on, total, renewal_mode, verified?}
  @others [
    {"Elevator maintenance, Harbourfront Tower", "Upward Lift Services", ["Harbourfront Tower"],
     ["Elevator maintenance"], ~D[2024-06-01], ~D[2027-05-31], "36000", :renew_on_request, true},
    {"Window cleaning, Maple Court", "ClearView Window Co.", ["Maple Court"], ["Window cleaning"],
     ~D[2026-03-01], ~D[2027-02-28], "9600", :renew_on_request, true},
    {"Landscaping, Bayview Gardens", "GreenScape Landscaping",
     ["Bayview Gardens", "Queensway Plaza", "Lakeshore Terrace"], ["Landscaping"], ~D[2025-11-01],
     ~D[2026-10-31], "16200", :ends_on_expiry, false},
    {"HVAC & boiler service, Harbourfront Tower", "Summit HVAC",
     ["Harbourfront Tower", "Maple Court", "King West Lofts"],
     ["HVAC maintenance", "Boiler service"], ~D[2025-11-03], ~D[2026-11-02], "48000",
     :auto_extend, false},
    {"Fire alarm inspection", "Sentinel Fire Protection",
     ["Harbourfront Tower", "Bayview Gardens", "Riverside Commons"], ["Fire safety inspection"],
     ~D[2025-11-16], ~D[2026-11-15], "7200", :auto_extend, false},
    {"Pest control portfolio agreement", "Pestaway",
     [
       "Maple Court",
       "Bayview Gardens",
       "King West Lofts",
       "Riverside Commons",
       "Elm Park Residences"
     ], ["Pest control"], ~D[2025-10-02], ~D[2027-10-01], "21600", :auto_extend, true},
    {"Security patrol, Queensway Plaza", "Guardian Security",
     ["Queensway Plaza", "Lakeshore Terrace", "Elm Park Residences"], ["Security"],
     ~D[2025-10-01], ~D[2027-09-30], "96000", :auto_extend, false},
    {"Window cleaning 2025–2026", "ClearView Window Co.",
     ["King West Lofts", "Maple Court", "Riverside Commons"], ["Window cleaning"], ~D[2025-04-01],
     ~D[2026-03-31], "11400", :ends_on_expiry, false},
    {"Parking lot sweeping", "ShineBright Janitorial",
     ["Queensway Plaza", "Bayview Gardens", "Lakeshore Terrace"], ["Sweeping"], ~D[2025-05-01],
     ~D[2026-04-30], "6000", :ends_on_expiry, true},
    {"Common area painting", "Colourline Painting",
     ["Riverside Commons", "Maple Court", "Elm Park Residences"], ["Painting"], ~D[2026-06-01],
     ~D[2027-12-31], "42000", :renew_on_request, true},
    {"Plumbing & backflow testing, Lakeshore", "PureFlow Plumbing",
     ["Lakeshore Terrace", "Queensway Plaza", "Bayview Gardens"],
     ["Plumbing", "Backflow testing"], ~D[2026-01-01], ~D[2027-12-31], "18000", :renew_on_request,
     true}
  ]

  def run do
    landscaping()
    Enum.each(@others, &other/1)
    :ok
  end

  defp landscaping do
    name = "Landscaping & snow removal, North portfolio"

    unless exists?(name) do
      contract =
        create!(Contract, :record, %{
          name: name,
          vendor_name: "GreenScape Landscaping",
          pmc_name: "PMC Management",
          property_manager_name: "Marcus Chen",
          enterprise_leader_name: "Jennifer Doe",
          intake: :uploaded_paper,
          deal_origin: :off_platform_quote,
          recorded_on: ~D[2024-11-12],
          starts_on: ~D[2025-01-01],
          expires_on: ~D[2026-12-31],
          notice_period_days: 60,
          renewal_mode: :auto_extend,
          total_value: Decimal.new("86400")
        })

      for {property, address} <- @properties,
          {service, amount, cadence} <- [
            {"Landscaping", "450", :month},
            {"Snow removal", "5400", :season}
          ] do
        create!(ContractLine, :create, %{
          contract_id: contract.id,
          property_name: property,
          property_address: address,
          service: service,
          starts_on: ~D[2025-01-01],
          ends_on: ~D[2026-12-31],
          amount: Decimal.new(amount),
          cadence: cadence
        })
      end

      # 12 values read from the signed PDF; the indemnity and payment terms
      # were already checked, which leaves the design's "8 to check".
      [
        {:renewal_terms, :expires_on, "Expiry date", "Dec 31, 2026", 2, false},
        {:renewal_terms, :notice_period_days, "Notice period", "60 days", 2, false},
        {:renewal_terms, :renewal_mode, "Renewal mode", "Auto-extend", 2, false},
        {:contract_value, :total_value, "Total value", "$86,400", 3, false},
        {:termination, :for_convenience, "Termination for convenience", "60 days' written notice",
         4, false},
        {:termination, :for_cause, "Termination for cause",
         "Immediately, on written notice of material breach", 4, false},
        {:insurance, :general_liability, "Commercial general liability",
         "$2,000,000 per occurrence", 5, false},
        {:insurance, :additional_insured, "Additional insured",
         "PMC Management and the property owner", 5, false},
        {:indemnity, :vendor_indemnifies, "Vendor indemnifies",
         "Owner, PMC Management and their agents", 6, true},
        {:indemnity, :exception, "Exception",
         "Gross negligence or wilful misconduct of the Owner", 6, true},
        {:payment_terms, :invoicing, "Invoicing", "Monthly, in arrears", 7, true},
        {:payment_terms, :payment_due, "Payment due", "Net 30 days from invoice", 7, true}
      ]
      |> Enum.with_index()
      |> Enum.each(fn {{section, field, label, value, page, confirmed?}, position} ->
        extracted =
          create!(ExtractedValue, :create, %{
            contract_id: contract.id,
            section: section,
            field: field,
            label: label,
            value: value,
            page: page,
            position: position
          })

        if confirmed?, do: Ash.update!(extracted, %{}, action: :confirm, authorize?: false)
      end)

      [
        {"Spring cleanup", ~D[2026-08-02], :completed},
        {"Summer pruning", ~D[2026-10-04], :overdue},
        {"Fall cleanup", ~D[2026-11-06], :upcoming},
        {"Winterizing", ~D[2027-01-08], :upcoming}
      ]
      |> Enum.each(fn {title, due_on, status} ->
        create!(ScheduledWork, :create, %{
          contract_id: contract.id,
          title: title,
          scope: "All 4 properties",
          due_on: due_on,
          status: status
        })
      end)

      create!(ContractDocument, :create, %{
        contract_id: contract.id,
        version: 1,
        kind: :signed_agreement,
        filename: "landscaping-snow-removal-north-p-signed.pdf",
        uploaded_on: ~D[2024-12-12]
      })
    end
  end

  defp other({name, vendor, properties, services, starts_on, expires_on, total, mode, verified?}) do
    unless exists?(name) do
      contract =
        create!(Contract, :record, %{
          name: name,
          vendor_name: vendor,
          pmc_name: "PMC Management",
          property_manager_name: "Marcus Chen",
          intake: if(verified?, do: :signed_on_platform, else: :uploaded_paper),
          template_name: if(verified?, do: "Standard services agreement"),
          deal_origin: if(verified?, do: :rfq_award, else: :off_platform_quote),
          recorded_on: starts_on,
          starts_on: starts_on,
          expires_on: expires_on,
          notice_period_days: 30,
          renewal_mode: mode,
          total_value: Decimal.new(total)
        })

      for property <- properties, service <- services do
        create!(ContractLine, :create, %{
          contract_id: contract.id,
          property_name: property,
          property_address: address(property),
          service: service,
          starts_on: starts_on,
          ends_on: expires_on,
          amount:
            Decimal.new(total)
            |> Decimal.div(length(properties) * length(services) * 12)
            |> Decimal.round(0),
          cadence: :month
        })
      end

      # An uploaded contract nobody has checked yet: the AI's read of its
      # expiry date is waiting for a person.
      unless verified? do
        create!(ExtractedValue, :create, %{
          contract_id: contract.id,
          section: :renewal_terms,
          field: "expires_on",
          label: "Expiry date",
          value: Calendar.strftime(expires_on, "%b %-d, %Y"),
          page: 1,
          position: 0
        })
      end

      create!(ContractDocument, :create, %{
        contract_id: contract.id,
        version: 1,
        kind: :signed_agreement,
        filename:
          "#{name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")}-signed.pdf",
        uploaded_on: starts_on
      })
    end
  end

  defp address(property) do
    Enum.find_value(@properties, fn {name, address} -> name == property && address end) ||
      Map.fetch!(@addresses, property)
  end

  defp exists?(name) do
    require Ash.Query

    Contract
    |> Ash.Query.filter(name == ^name)
    |> Ash.exists?(authorize?: false)
  end

  defp create!(resource, action, attrs) do
    resource
    |> Ash.Changeset.for_create(action, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end
end
