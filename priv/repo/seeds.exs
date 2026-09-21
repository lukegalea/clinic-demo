# Run with: mix run priv/repo/seeds.exs
#
# A day's worth of schedule, so the introspection tools have something to
# describe and the queries have something to return.

alias ClinicDemo.Scheduling

# The appointment policies require an actor; any signed-in staff member will
# do. This demo has no authentication, so a bare map stands in for one.
staff = %{id: "seed", role: :veterinarian}

{:ok, vet} =
  Scheduling.hire_clinician(%{
    full_name: "Dr. Amara Osei",
    role: :veterinarian,
    license_number: "ON-104422"
  })

{:ok, tech} =
  Scheduling.hire_clinician(%{full_name: "Jonah Reyes", role: :technician})

patients =
  for attrs <- [
        %{
          name: "Biscuit",
          species: :dog,
          breed: "Beagle",
          date_of_birth: ~D[2019-04-11],
          weight_kg: Decimal.new("11.4"),
          microchip_number: "900215000123456",
          owner_email: "dana.kirby@example.com"
        },
        %{
          name: "Pepper",
          species: :cat,
          breed: "Domestic Shorthair",
          date_of_birth: ~D[2021-08-02],
          weight_kg: Decimal.new("4.2"),
          owner_email: "Sam.Whitfield@example.com"
        },
        %{
          name: "Clover",
          species: :rabbit,
          owner_email: "priya.nair@example.com"
        }
      ] do
    {:ok, patient} = Scheduling.register_patient(attrs)
    patient
  end

[biscuit, pepper, clover] = patients

tomorrow_at = fn hour ->
  Date.utc_today()
  |> Date.add(1)
  |> DateTime.new!(Time.new!(hour, 0, 0), "Etc/UTC")
end

{:ok, _} =
  Scheduling.book_appointment(
    %{
      patient_id: biscuit.id,
      clinician_id: vet.id,
      scheduled_at: tomorrow_at.(9),
      duration_minutes: 30,
      reason: "Limping on the right foreleg since Saturday"
    },
    actor: staff
  )

{:ok, pepper_visit} =
  Scheduling.book_appointment(
    %{
      patient_id: pepper.id,
      clinician_id: vet.id,
      scheduled_at: tomorrow_at.(10),
      duration_minutes: 20,
      reason: "Annual vaccination"
    },
    actor: staff
  )

{:ok, _} =
  Scheduling.book_appointment(
    %{
      patient_id: clover.id,
      clinician_id: tech.id,
      scheduled_at: tomorrow_at.(11),
      duration_minutes: 15,
      reason: "Nail trim"
    },
    actor: staff
  )

# Walk one appointment through its whole lifecycle so the data is not all in
# the same state.
{:ok, pepper_visit} = Scheduling.check_in_appointment(pepper_visit, actor: staff)

{:ok, _} =
  Scheduling.complete_appointment(
    pepper_visit,
    "Vaccinated against FVRCP and rabies. No adverse reaction observed.",
    actor: staff
  )

{:ok, _} = Scheduling.record_weight(pepper, Decimal.new("4.35"))

IO.puts("""
Seeded:
  #{length(Scheduling.list_clinicians!())} clinicians
  #{length(Scheduling.list_patients!())} patients
  #{length(Scheduling.list_appointments!())} appointments
""")
