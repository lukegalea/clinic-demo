defmodule ClinicDemo.Scheduling.PatientTest do
  use ClinicDemo.DataCase, async: true

  alias ClinicDemo.Scheduling

  # Just someone acting — the policies check presence, not identity.
  @staff %{id: "00000000-0000-0000-0000-0000000000ee", role: :veterinarian}

  defp email, do: "owner-#{System.unique_integer([:positive])}@example.com"

  test "registration rejects a malformed owner email" do
    assert {:error, %Ash.Error.Invalid{}} =
             Scheduling.register_patient(
               %{
                 name: "Rex",
                 species: :dog,
                 owner_email: "not-an-email"
               },
               actor: @staff
             )
  end

  test "registration rejects a species the clinic does not see" do
    assert {:error, %Ash.Error.Invalid{}} =
             Scheduling.register_patient(
               %{
                 name: "Nessie",
                 species: :plesiosaur,
                 owner_email: email()
               },
               actor: @staff
             )
  end

  test "registration rejects a microchip that is not fifteen digits" do
    assert {:error, %Ash.Error.Invalid{}} =
             Scheduling.register_patient(
               %{
                 name: "Rex",
                 species: :dog,
                 microchip_number: "12345",
                 owner_email: email()
               },
               actor: @staff
             )
  end

  test "record_weight is the only way weight changes" do
    {:ok, patient} =
      Scheduling.register_patient(%{name: "Rex", species: :dog, owner_email: email()},
        actor: @staff
      )

    assert is_nil(patient.weight_kg)

    {:ok, patient} = Scheduling.record_weight(patient, Decimal.new("18.2"), actor: @staff)
    assert Decimal.equal?(patient.weight_kg, Decimal.new("18.2"))

    assert {:error, %Ash.Error.Invalid{}} =
             Scheduling.record_weight(patient, Decimal.new("0"), actor: @staff)
  end

  test "age_in_days is nil when the date of birth is unknown" do
    {:ok, known} =
      Scheduling.register_patient(
        %{
          name: "Rex",
          species: :dog,
          date_of_birth: Date.add(Date.utc_today(), -100),
          owner_email: email()
        },
        actor: @staff
      )

    {:ok, unknown} =
      Scheduling.register_patient(%{name: "Clover", species: :rabbit, owner_email: email()},
        actor: @staff
      )

    assert %{age_in_days: 100} = Ash.load!(known, :age_in_days)
    assert %{age_in_days: nil} = Ash.load!(unknown, :age_in_days)
  end

  # The audit's finding: with no policies, an anonymous Record weight mutated
  # a patient 11.4 -> 77.7 while nobody was acting. These are the gate the
  # "No one is acting." banner advertises.
  test "writing without an actor is refused" do
    assert {:error, %Ash.Error.Forbidden{}} =
             Scheduling.register_patient(%{name: "Rex", species: :dog, owner_email: email()})

    {:ok, patient} =
      Scheduling.register_patient(%{name: "Rex", species: :dog, owner_email: email()},
        actor: @staff
      )

    assert {:error, %Ash.Error.Forbidden{}} =
             Scheduling.record_weight(patient, Decimal.new("77.7"))
  end

  test "reading without an actor is allowed" do
    {:ok, patient} =
      Scheduling.register_patient(%{name: "Rex", species: :dog, owner_email: email()},
        actor: @staff
      )

    patients = Scheduling.list_patients!()
    assert Enum.any?(patients, &(&1.id == patient.id))
  end
end
