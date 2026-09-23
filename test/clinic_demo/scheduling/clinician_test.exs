defmodule ClinicDemo.Scheduling.ClinicianTest do
  use ClinicDemo.DataCase, async: true

  alias ClinicDemo.Scheduling

  @staff %{id: "00000000-0000-0000-0000-0000000000ef", role: :veterinarian}

  defp license, do: "ON-#{:rand.uniform(899_999) + 100_000}"

  # The audit retired a clinician with nobody acting. Same two-policy shape
  # as Appointment and Patient; these are its teeth on the roster.
  test "writing without an actor is refused" do
    assert {:error, %Ash.Error.Forbidden{}} =
             Scheduling.hire_clinician(%{full_name: "Anon Hire", role: :nurse})

    {:ok, vet} =
      Scheduling.hire_clinician(
        %{full_name: "Dr. Gated", role: :veterinarian, license_number: license()},
        actor: @staff
      )

    assert {:error, %Ash.Error.Forbidden{}} = Scheduling.retire_clinician(vet)
  end

  test "reading without an actor is allowed" do
    {:ok, vet} =
      Scheduling.hire_clinician(
        %{full_name: "Dr. Visible", role: :veterinarian, license_number: license()},
        actor: @staff
      )

    assert vet.id in Enum.map(Scheduling.list_clinicians!(), & &1.id)
  end
end
