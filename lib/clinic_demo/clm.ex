defmodule ClinicDemo.Clm do
  @moduledoc """
  Contract Management (CLM 2.0) POC: the contract page of the CLM 2.0 design,
  declared rather than drawn.

  A contract, the lines it prices (property × service), the values the AI
  extracted from its signed document and a person has to check, the work it
  schedules, and its document versions. The contract is *verified* when no
  extracted value is left to check: verification is derived from the values,
  never set by hand.

  Not a VendorPM model. Names follow the design so the page reads the same;
  every record in `ClinicDemo.Clm.Seeds` is invented.
  """

  use Ash.Domain

  resources do
    resource ClinicDemo.Clm.Contract do
      define :list_contracts, action: :read
      define :get_contract, action: :read, get_by: [:id]
    end

    resource ClinicDemo.Clm.ContractLine
    resource ClinicDemo.Clm.ExtractedValue
    resource ClinicDemo.Clm.ScheduledWork
    resource ClinicDemo.Clm.ContractDocument
  end
end
