# Run with: mix run priv/repo/seeds.exs
#
# A day's worth of schedule, so the introspection tools have something to
# describe and the queries have something to return.

alias ClinicDemo.Scheduling

# The appointment policies require an actor; any signed-in staff member will
# do. This demo has no authentication, so a bare map stands in for one. The id
# is a UUID because the process records who started an instance in a uuid
# column, and a seed that could not be attributed would not be much of a trail.
staff = %{id: "00000000-0000-0000-0000-0000000000aa", role: :veterinarian}

# The rules first, and in this order: the visit process will not compile until
# the decision it references is published. Booking an appointment below starts
# an instance of that process, so nothing after this line would work without
# it.
%{decision: decision, process: process} = ClinicDemo.Rules.install!()

IO.puts("""
Published:
  #{decision.key} v#{decision.version} (#{decision.status})
  #{process.key} v#{process.version} (#{process.status})
""")

# The board's lanes, before any bookings: the process stages cards move
# through, matched by Appointment.board_lane. Idempotent by key so reseeding
# never duplicates or reorders them behind the seeds' back.
require Ash.Query

lane_rows = [
  %{lane_key: "intake", label: "Intake", position: 1, accent: "neutral"},
  %{lane_key: "low", label: "Low — routine", position: 2, accent: "green"},
  %{lane_key: "medium", label: "Medium — soon", position: 3, accent: "amber"},
  %{lane_key: "high", label: "High — urgent & emergency", position: 4, accent: "red"},
  %{lane_key: "in_visit", label: "In visit", position: 5, accent: "violet"},
  %{lane_key: "discharged", label: "Discharged", position: 6, accent: "blue"},
  %{lane_key: "closed", label: "Closed", position: 7, accent: "neutral"}
]

for row <- lane_rows do
  ClinicDemo.Scheduling.BoardLane
  |> Ash.Query.filter(lane_key == ^row.lane_key)
  |> Ash.read_one!(authorize?: false)
  |> case do
    nil ->
      ClinicDemo.Scheduling.BoardLane
      |> Ash.Changeset.for_create(:create, row)
      |> Ash.create!(authorize?: false)

    lane ->
      lane
      |> Ash.Changeset.for_update(:update, row)
      |> Ash.update!(authorize?: false)
  end
end

{:ok, vet} =
  Scheduling.hire_clinician(%{
    full_name: "Dr. Amara Osei",
    role: :veterinarian,
    license_number: "ON-104422"
  })

{:ok, tech} =
  Scheduling.hire_clinician(%{full_name: "Jonah Reyes", role: :technician})

# The front desk. `CheckIn` in the visit process is assigned to every active
# nurse, resolved out of this table rather than out of the diagram.
{:ok, nurse} = Scheduling.hire_clinician(%{full_name: "Ruth Vance", role: :nurse})

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
      reason: "Limping on the right foreleg since Saturday",
      severity: 2
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
      reason: "Annual vaccination",
      severity: 1
    },
    actor: staff
  )

{:ok, clover_visit} =
  Scheduling.book_appointment(
    %{
      patient_id: clover.id,
      clinician_id: tech.id,
      scheduled_at: tomorrow_at.(11),
      duration_minutes: 15,
      reason: "Off her food and quieter than usual",
      severity: 3
    },
    actor: staff
  )

# ── Walking two visits through the process ─────────────────────────────────
#
# Every appointment above already has an instance: booking started one. What
# follows moves two of them along, so the seeded data is not three identical
# rows sitting on the same node.
#
# Nothing here reaches into the engine. Each step is a person completing the
# work item in front of them, and the process does the rest.

require Ash.Query

open_task = fn appointment, node_id ->
  ClinicDemo.Visits.HumanTask
  |> Ash.Query.for_read(:read)
  |> Ash.Query.filter(node_id == ^node_id and status in [:open, :claimed])
  |> Ash.read!()
  |> Enum.find(fn task ->
    instance = Ash.get!(ClinicDemo.Visits.Instance, task.instance_id)
    instance.subject_id == appointment.id
  end)
end

# Pepper: in, seen, written up, out.
{:ok, _} =
  AshBpmn.complete_task(open_task.(pepper_visit, "CheckIn"),
    outcome: :arrived,
    actor: %{id: nurse.id}
  )

pepper_visit = Scheduling.get_appointment!(pepper_visit.id)

{:ok, _} =
  Scheduling.complete_appointment(
    pepper_visit,
    "Vaccinated against FVRCP and rabies. No adverse reaction observed.",
    actor: staff
  )

{:ok, _} =
  AshBpmn.complete_task(open_task.(pepper_visit, "Consult"),
    outcome: :written_up,
    comment: "Nothing else to follow up.",
    actor: %{id: vet.id}
  )

# Clover: in, seen, bloods sent. This instance is parked on `AwaitLabResults`,
# which is the wait state, and it will stay there until somebody in the lab
# completes that task.
{:ok, _} =
  AshBpmn.complete_task(open_task.(clover_visit, "CheckIn"),
    outcome: :arrived,
    actor: %{id: nurse.id}
  )

clover_visit = Scheduling.get_appointment!(clover_visit.id)

{:ok, _} =
  Scheduling.complete_appointment(
    clover_visit,
    "Reduced gut sounds. Bloods sent; holding discharge until they are back.",
    actor: staff
  )

{:ok, _} =
  AshBpmn.complete_task(open_task.(clover_visit, "Consult"),
    outcome: :labs_pending,
    comment: "Biochem and PCV requested.",
    actor: %{id: tech.id}
  )

{:ok, _} = Scheduling.record_weight(pepper, Decimal.new("4.35"))

waiting =
  ClinicDemo.Visits.HumanTask
  |> Ash.Query.for_read(:read)
  |> Ash.Query.filter(status in [:open, :claimed])
  |> Ash.read!()

IO.puts("""
Seeded:
  #{length(Scheduling.list_clinicians!())} clinicians
  #{length(Scheduling.list_patients!())} patients
  #{length(Scheduling.list_appointments!())} appointments
  #{length(Scheduling.list_appointments!())} visit instances
  #{length(waiting)} work items waiting: #{waiting |> Enum.map(& &1.node_id) |> Enum.sort() |> Enum.join(", ")}

Triage decided:
#{Scheduling.list_appointments!() |> Enum.map_join("\n", fn a -> "  #{a.reason} -> #{a.triage_urgency}" end)}
""")
