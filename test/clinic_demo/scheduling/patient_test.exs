defmodule ClinicDemo.Scheduling.PatientTest do
  use ClinicDemo.DataCase, async: true

  alias ClinicDemo.Scheduling

  defp email, do: "owner-#{System.unique_integer([:positive])}@example.com"

  test "registration rejects a malformed owner email" do
    assert {:error, %Ash.Error.Invalid{}} =
             Scheduling.register_patient(%{
               name: "Rex",
               species: :dog,
               owner_email: "not-an-email"
             })
  end

  test "registration rejects a species the clinic does not see" do
    assert {:error, %Ash.Error.Invalid{}} =
             Scheduling.register_patient(%{
               name: "Nessie",
               species: :plesiosaur,
               owner_email: email()
             })
  end

  test "registration rejects a microchip that is not fifteen digits" do
    assert {:error, %Ash.Error.Invalid{}} =
             Scheduling.register_patient(%{
               name: "Rex",
               species: :dog,
               microchip_number: "12345",
               owner_email: email()
             })
  end

  test "record_weight is the only way weight changes" do
    {:ok, patient} =
      Scheduling.register_patient(%{name: "Rex", species: :dog, owner_email: email()})

    assert is_nil(patient.weight_kg)

    {:ok, patient} = Scheduling.record_weight(patient, Decimal.new("18.2"))
    assert Decimal.equal?(patient.weight_kg, Decimal.new("18.2"))

    assert {:error, %Ash.Error.Invalid{}} =
             Scheduling.record_weight(patient, Decimal.new("0"))
  end

  test "age_in_days is nil when the date of birth is unknown" do
    {:ok, known} =
      Scheduling.register_patient(%{
        name: "Rex",
        species: :dog,
        date_of_birth: Date.add(Date.utc_today(), -100),
        owner_email: email()
      })

    {:ok, unknown} =
      Scheduling.register_patient(%{name: "Clover", species: :rabbit, owner_email: email()})

    assert %{age_in_days: 100} = Ash.load!(known, :age_in_days)
    assert %{age_in_days: nil} = Ash.load!(unknown, :age_in_days)
  end
end
