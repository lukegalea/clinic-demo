defmodule ClinicDemo.FhirTest do
  @moduledoc """
  The FHIR-named façades over the scheduling resources.

  A façade owns no rows, so what is worth testing is what it hands on and what
  it refuses: the vocabulary arrives translated, a read as of an instant reads
  the temporal appointments as of that instant, and a write is the source
  action or nothing. The negative cases check the source row afterwards,
  because a refusal that still changed the appointment is not a refusal.
  """

  use ClinicDemo.DataCase, async: true

  alias ClinicDemo.Fhir
  alias ClinicDemo.Fhir.{Encounter, Location, Patient, Practitioner}
  alias ClinicDemo.Scheduling
  alias ClinicDemoWeb.A2ui.EncounterUI

  # A UUID, because booking starts a visit process and the instance records
  # who acted in uuid columns.
  @staff %{id: "00000000-0000-0000-0000-0000000000ee", role: :veterinarian}

  defp hours_ago(hours),
    do: DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)

  defp fixtures do
    vet =
      Scheduling.hire_clinician!(
        %{
          full_name: "Dr. Facade Vet",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    patient =
      Scheduling.register_patient!(
        %{
          name: "Facade Animal",
          species: :cat,
          microchip_number:
            "9#{String.pad_leading("#{System.unique_integer([:positive])}", 14, "0")}",
          owner_email: "facade-#{System.unique_integer([:positive])}@example.com"
        },
        actor: @staff
      )

    %{vet: vet, patient: patient}
  end

  defp book!(vet, patient, reason) do
    Scheduling.book_appointment!(
      %{
        patient_id: patient.id,
        clinician_id: vet.id,
        scheduled_at:
          DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
        duration_minutes: 30,
        reason: reason,
        severity: 2
      },
      actor: @staff
    )
  end

  # Booked, then checked in: the appointment has two versions, and `between`
  # is an instant after the first write and before the second, so an as-of read
  # at it sees the visit as it was before the check-in. Both writes take effect
  # now, as the application's own callers do; back-dating one would leave the
  # process's later triage version as the one valid now.
  defp checked_in_visit do
    %{vet: vet, patient: patient} = fixtures()
    appointment = book!(vet, patient, "Facade walk")
    between = DateTime.utc_now()

    Scheduling.check_in_appointment!(Scheduling.get_appointment!(appointment.id),
      actor: @staff
    )

    %{appointment: appointment, patient: patient, vet: vet, between: between}
  end

  defp booked_visit do
    %{vet: vet, patient: patient} = fixtures()
    book!(vet, patient, "Facade planned")
  end

  defp encounter(id, opts \\ []) do
    Fhir.list_encounters!(Keyword.merge([actor: @staff, query: [filter: [id: id]]], opts))
  end

  defp source!(id), do: Scheduling.get_appointment!(id, actor: @staff)

  describe "the vocabulary" do
    test "a patient arrives under FHIR's names" do
      %{patient: patient} = fixtures()

      assert [row] = Fhir.list_fhir_patients!(actor: @staff, query: [filter: [id: patient.id]])
      assert %Patient{name: "Facade Animal", species: :cat} = row
      assert row.identifier == patient.microchip_number
      refute Map.has_key?(Map.from_struct(row), :owner_email)
    end

    test "a practitioner and a location arrive under FHIR's names" do
      %{vet: vet} = fixtures()

      location =
        Scheduling.register_service_location!(
          %{
            name: "Facade Farm",
            kind: :client_site,
            address_line: "1 Farm Road",
            city: "Guelph",
            latitude: Decimal.new("43.5"),
            longitude: Decimal.new("-80.2")
          },
          actor: @staff
        )

      assert [%Practitioner{name: "Dr. Facade Vet", qualification: :veterinarian} = practitioner] =
               Fhir.list_fhir_practitioners!(actor: @staff, query: [filter: [id: vet.id]])

      assert practitioner.identifier == vet.license_number

      assert [%Location{name: "Facade Farm", type: :client_site, city: "Guelph"}] =
               Fhir.list_fhir_locations!(actor: @staff, query: [filter: [id: location.id]])
    end

    test "an encounter's status is the appointment's, decoded" do
      %{appointment: appointment, patient: patient, vet: vet} = checked_in_visit()

      assert [%Encounter{} = row] = encounter(appointment.id)
      assert row.status == :arrived
      assert row.class == :ambulatory
      assert row.subject_id == patient.id
      assert row.practitioner_id == vet.id
      assert row.reason == "Facade walk"

      planned = booked_visit()
      assert [%Encounter{status: :planned}] = encounter(planned.id)
    end

    test "status filters through the lens" do
      %{appointment: appointment} = checked_in_visit()

      ids =
        Fhir.list_encounters!(actor: @staff, query: [filter: [status: :arrived]])
        |> Enum.map(& &1.id)

      assert appointment.id in ids

      assert [] =
               encounter(appointment.id, query: [filter: [id: appointment.id, status: :planned]])
    end
  end

  describe "as_of" do
    test "a read as of an earlier instant reads the appointment as it was" do
      %{appointment: appointment, between: between} = checked_in_visit()

      assert [%Encounter{status: :planned}] = encounter(appointment.id, as_of: between)
      assert [%Encounter{status: :arrived}] = encounter(appointment.id)
    end
  end

  describe "writes are named source actions" do
    test "finish runs the appointment's :complete" do
      %{appointment: appointment} = checked_in_visit()

      finished =
        Fhir.finish_encounter!(appointment.id, "Seen, wormed and sent home.", actor: @staff)

      assert finished.status == :finished
      assert finished.note == "Seen, wormed and sent home."

      source = source!(appointment.id)
      assert source.status == :completed
      assert source.notes == "Seen, wormed and sent home."
    end

    test "cancel runs the appointment's :cancel" do
      %{appointment: appointment} = checked_in_visit()

      cancelled = Fhir.cancel_encounter!(appointment.id, "Owner called it off", actor: @staff)

      assert cancelled.status == :cancelled
      assert cancelled.cancellation_reason == "Owner called it off"

      source = source!(appointment.id)
      assert source.status == :cancelled
      assert source.cancellation_reason == "Owner called it off"
    end

    test "the source's own guard refuses a finish the state machine does not allow" do
      appointment = booked_visit()

      assert {:error, _} =
               Fhir.finish_encounter(appointment.id, "Never checked in at all.", actor: @staff)

      assert source!(appointment.id).status == :scheduled
    end

    test "the source's own validation refuses a note it finds too short" do
      %{appointment: appointment} = checked_in_visit()

      assert {:error, _} = Fhir.finish_encounter(appointment.id, "ok", actor: @staff)
      assert source!(appointment.id).status == :checked_in
    end

    test "a caller the source's policy refuses cannot finish" do
      %{appointment: appointment} = checked_in_visit()

      assert {:error, %Ash.Error.Forbidden{}} =
               Fhir.finish_encounter(appointment.id, "Seen, wormed and sent home.", actor: nil)

      assert source!(appointment.id).status == :checked_in
    end

    test "a finish with a past as_of is refused and the appointment is unchanged" do
      %{appointment: appointment} = checked_in_visit()
      before = source!(appointment.id)

      assert {:error, error} =
               Fhir.finish_encounter(appointment.id, "Seen, wormed and sent home.",
                 actor: @staff,
                 as_of: hours_ago(2)
               )

      assert Exception.message(error) =~ "as_of"

      after_ = source!(appointment.id)
      assert after_.status == :checked_in
      assert after_.notes == nil
      assert after_.valid_at == before.valid_at
    end

    test "the façade declares no way to write status other than finish and cancel" do
      actions = Encounter |> Ash.Resource.Info.actions() |> Enum.map(& &1.name) |> Enum.sort()
      assert actions == [:cancel, :finish, :read]

      %{appointment: appointment} = checked_in_visit()
      [row] = encounter(appointment.id)

      assert_raise ArgumentError, ~r/No such update action/, fn ->
        row
        |> Ash.Changeset.for_update(:update, %{status: :planned}, actor: @staff)
        |> Ash.update!()
      end

      assert source!(appointment.id).status == :checked_in
    end
  end

  describe "the Encounter surface" do
    test "builds from the façade, and its rows are the viewer's encounters" do
      %{appointment: appointment} = checked_in_visit()

      assert Enum.any?(
               AshA2ui.Info.build_surface(EncounterUI, actor: @staff),
               &Map.has_key?(&1, "createSurface")
             )

      %{"updateDataModel" => %{"value" => value}} =
        AshA2ui.Info.build_data_model(EncounterUI, actor: @staff)

      row = Enum.find(value["records"], &(&1["id"] == appointment.id))
      assert row, "the encounter is not among the surface's records"
      assert row["_values"]["status"] == "arrived"
      assert row["reason"] == "Facade walk"
    end
  end
end
