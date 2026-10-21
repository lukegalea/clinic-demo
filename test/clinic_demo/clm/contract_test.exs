defmodule ClinicDemo.Clm.ContractTest do
  use ClinicDemo.DataCase, async: true

  alias ClinicDemo.Clm
  alias ClinicDemo.Clm.ExtractedValue

  require Ash.Query

  @staff %{id: "00000000-0000-0000-0000-0000000000c1"}

  setup do
    :ok = Clm.Seeds.run()

    contract =
      Clm.Contract
      |> Ash.Query.filter(name == "Landscaping & snow removal, North portfolio")
      |> Ash.read_one!()

    %{contract: contract}
  end

  defp reload(contract) do
    Ash.load!(contract, [
      :to_check_count,
      :verified?,
      :notice_deadline,
      :expiring_soon_on,
      :annual_value,
      :total_value_text,
      :renewal_mode_label
    ])
  end

  test "the lifecycle and value are derived from the dates and the total", %{contract: contract} do
    contract = reload(contract)

    assert contract.notice_deadline == ~D[2026-11-01]
    assert contract.expiring_soon_on == ~D[2026-08-03]
    assert Decimal.equal?(contract.annual_value, 43_200)
    assert contract.total_value_text == "$86,400"
    assert contract.renewal_mode_label == "Auto-extend"
  end

  test "a contract is verified once no extracted value is left to check", %{contract: contract} do
    assert %{to_check_count: 8, verified?: false} = reload(contract)

    for value <- to_check(contract) do
      Ash.update!(value, %{}, action: :confirm, actor: @staff)
    end

    assert %{to_check_count: 0, verified?: true} = reload(contract)
  end

  test "correcting a value replaces it and counts as checking it", %{contract: contract} do
    [value | _] = to_check(contract)

    corrected = Ash.update!(value, %{value: "Jan 31, 2027"}, action: :correct, actor: @staff)

    assert corrected.value == "Jan 31, 2027"
    assert corrected.confirmed_at
    assert reload(contract).to_check_count == 7
  end

  test "checking needs someone acting", %{contract: contract} do
    [value | _] = to_check(contract)

    assert {:error, %Ash.Error.Forbidden{}} = Ash.update(value, %{}, action: :confirm)
    assert reload(contract).to_check_count == 8
  end

  defp to_check(contract) do
    ExtractedValue
    |> Ash.Query.filter(contract_id == ^contract.id and is_nil(confirmed_at))
    |> Ash.read!()
  end
end
