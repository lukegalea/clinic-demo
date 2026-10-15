# Run with: mix run priv/repo/seeds.exs
#
# A day's worth of schedule, so the introspection tools have something to
# describe and the queries have something to return — and a short HISTORY
# behind it: bookings, triage decisions, check-ins that pass the weight
# guard, write-ups, a discharge, a no-show, a cancellation, and process
# instances with real token histories, so the operator surfaces (Audit,
# Evidence, Evaluations, the instance viewers) have something to show on
# first boot.
#
# Every action that policy gates runs WITH an acting clinician, so the logs
# and instance records attribute each step to the person (or seed stand-in)
# who took it.
#
# ── The seed writes its history as temporal writes ─────────────────────────
#
# `Appointment` is a temporal resource, and the board's time travel reads it
# as of an instant — which only has something to show if the lifecycle's
# stages were written at spaced instants, not all in one heap at seed time.
# So every appointment step below carries `as_of:`: booked three hours ago,
# triaged two hours ago, checked in an hour ago, written up half an hour
# ago. Each back-dated write SPLITS the version valid at that instant, which
# is the whole trick — no raw SQL touches the table (the temporal tables'
# locking only protects Ash writes), and no row id ever changes.
#
# One mechanic needs naming. Booking starts the visit process, and the
# engine's synchronous triage write happens at seed-run wall clock (the
# engine is not temporal), opening a version at "now". The back-dated steps
# split everything BEFORE that version, so after a back-dated walk the open
# version would still read `scheduled` — the present would disagree with the
# story the history tells. Hence each walk that ends on a back-dated write
# finishes with a RE-ASSERT: the same steps replayed at the present, so the
# open version owns the true final state and the engine's later writes
# (discharge, no-show) meet the status they expect. The cost is honest and
# tiny: between the engine's triage write and the re-assert (seconds apart,
# both at seed-run time) the board's history reads `scheduled` — an instant
# a visitor is never given a reason to pick.

alias ClinicDemo.Scheduling

# The appointment policies require an actor; any signed-in staff member will
# do. This demo has no authentication, so a bare map stands in for one. The id
# is a UUID because the process records who started an instance in a uuid
# column, and a seed that could not be attributed would not be much of a trail.
staff = %{id: "00000000-0000-0000-0000-0000000000aa", role: :veterinarian}

# The rules first, and in this order: the visit process will not compile until
# the decision it references is published. Booking an appointment below starts
# an instance of that process, so nothing after this line would work without
# it. The value ledger's mapping rules deploy with them (BPSim BD-2): the
# lifecycle hooks below record a value event for every moment the walk
# performs, and those events carry provenance pointing at an active mapping
# version — so the mappings must be active before the first booking.
%{decision: decision, process: process} = ClinicDemo.Rules.install!()
mapping_versions = ClinicDemo.BusinessEvents.install!()

IO.puts("""
Published:
  #{decision.key} v#{decision.version} (#{decision.status})
  #{process.key} v#{process.version} (#{process.status})
  #{length(mapping_versions)} value-event mappings active
""")

# The board's lanes, before any bookings: the process stages cards move
# through, matched by Appointment.board_lane. Idempotent by key so reseeding
# never duplicates or reorders them behind the seeds' back.
require Ash.Query

lane_rows = [
  %{lane_key: "intake", label: "Booked", position: 1, accent: "neutral"},
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

# ── Idempotency helpers ────────────────────────────────────────────────────
#
# Everything below the lanes is lookup-or-create keyed on a natural value
# (a license, an owner email, patient + reason), so re-running the seeds
# against a populated dev database updates what exists instead of crashing
# on a unique index or piling up duplicates.

clinician_by = fn opts ->
  opts = Map.new(opts)
  query = ClinicDemo.Scheduling.Clinician |> Ash.Query.for_read(:read)

  query =
    if opts[:license_number] do
      Ash.Query.filter(query, license_number == ^opts.license_number)
    else
      Ash.Query.filter(query, full_name == ^opts.full_name)
    end

  Ash.read_one!(query, authorize?: false)
end

patient_by = fn opts ->
  opts = Map.new(opts)

  ClinicDemo.Scheduling.Patient
  |> Ash.Query.for_read(:read)
  |> Ash.Query.filter(owner_email == ^opts.owner_email)
  |> Ash.read_one!(authorize?: false)
end

appointment_by = fn patient_id, reason ->
  ClinicDemo.Scheduling.Appointment
  |> Ash.Query.for_read(:read)
  |> Ash.Query.filter(patient_id == ^patient_id and reason == ^reason)
  |> Ash.read_one!(authorize?: false)
end

{:ok, vet} =
  case clinician_by.(license_number: "ON-104422") do
    nil ->
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Amara Osei",
          role: :veterinarian,
          license_number: "ON-104422"
        },
        actor: staff
      )

    clinician ->
      {:ok, clinician}
  end

{:ok, tech} =
  case clinician_by.(full_name: "Jonah Reyes") do
    nil -> Scheduling.hire_clinician(%{full_name: "Jonah Reyes", role: :technician}, actor: staff)
    clinician -> {:ok, clinician}
  end

# The front desk. `CheckIn` in the visit process is assigned to every active
# nurse, resolved out of this table rather than out of the diagram.
{:ok, nurse} =
  case clinician_by.(full_name: "Ruth Vance") do
    nil -> Scheduling.hire_clinician(%{full_name: "Ruth Vance", role: :nurse}, actor: staff)
    clinician -> {:ok, clinician}
  end

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
    case patient_by.(owner_email: attrs.owner_email) do
      nil ->
        {:ok, patient} = Scheduling.register_patient(attrs, actor: staff)
        patient

      patient ->
        patient
    end
  end

[biscuit, pepper, clover] = patients

tomorrow_at = fn hour ->
  Date.utc_today()
  |> Date.add(1)
  |> DateTime.new!(Time.new!(hour, 0, 0), "Etc/UTC")
end

# The history clock: UTC instants N hours before the seed ran, second-
# truncated like every timestamp the demo stamps. The lifecycle steps
# below write at these.
hours_ago = fn hours ->
  DateTime.utc_now()
  |> DateTime.add(-hours * 60 * 60, :second)
  |> DateTime.truncate(:second)
end

booked_at = hours_ago.(3)
triaged_at = hours_ago.(2)
checked_in_at = hours_ago.(1)
completed_at = hours_ago.(1) |> DateTime.add(30 * 60, :second) |> DateTime.truncate(:second)

# Whether the visit's HISTORY already carries triage at `at` — the temporal
# read itself is the reseed guard: the version valid at that instant either
# has the answer or the re-assert is due. (The appointment exists at `at` in
# every seed run: bookings land three hours back, the triage instant two.)
triage_in_history? = fn appointment, at ->
  Ash.get!(ClinicDemo.Scheduling.Appointment, appointment.id, as_of: at).triage_urgency != nil
end

# The triage the engine recorded at seed-run time, re-asserted at the
# history's instant (see the header note): the board as of two hours ago
# shows the visit in its triage lane, not still sitting in Booked. The
# write's subject is the version valid AT the triage instant — a temporal
# write's validations read the loaded record, so the record must be the
# as-of one — and the write runs BEFORE a walk's back-dated steps, so the
# periods land in history order (a visit is triaged before it is checked
# in, at every instant).
record_triage_in_history = fn appointment, actor ->
  if appointment.triage_urgency && not triage_in_history?.(appointment, triaged_at) do
    version = Scheduling.get_appointment!(appointment.id, as_of: triaged_at)

    Scheduling.record_appointment_triage!(version, appointment.triage_urgency,
      actor: actor,
      as_of: triaged_at
    )
  end
end

book = fn patient, clinician, attrs ->
  case appointment_by.(patient.id, attrs.reason) do
    nil ->
      Scheduling.book_appointment(
        Map.merge(
          %{
            patient_id: patient.id,
            clinician_id: clinician.id,
            scheduled_at: tomorrow_at.(9),
            duration_minutes: 30,
            severity: 2
          },
          attrs
        ),
        actor: staff,
        # Every booking lands in the history three hours back; the visit
        # process it starts is a present-tense side effect (the engine is
        # not temporal) — see the header note.
        as_of: booked_at
      )

    existing ->
      {:ok, existing}
  end
end

{:ok, _} =
  book.(biscuit, vet, %{
    scheduled_at: tomorrow_at.(9),
    duration_minutes: 30,
    reason: "Limping on the right foreleg since Saturday",
    severity: 2
  })

{:ok, pepper_visit} =
  book.(pepper, vet, %{
    scheduled_at: tomorrow_at.(10),
    duration_minutes: 20,
    reason: "Annual vaccination",
    severity: 1
  })

{:ok, clover_visit} =
  book.(clover, tech, %{
    scheduled_at: tomorrow_at.(11),
    duration_minutes: 15,
    reason: "Off her food and quieter than usual",
    severity: 3
  })

# Two more bookings, so the seeded history can show the closed sides of the
# lifecycle (a no-show and a cancellation) rather than only open lanes.
{:ok, biscuit_no_show_visit} =
  book.(biscuit, vet, %{
    scheduled_at: tomorrow_at.(13),
    duration_minutes: 15,
    reason: "Nail trim",
    severity: 1
  })

{:ok, pepper_cancelled_visit} =
  book.(pepper, vet, %{
    scheduled_at: tomorrow_at.(14),
    duration_minutes: 20,
    reason: "Skin allergy recheck",
    severity: 2
  })

# One visit from EARLIER TODAY, so the Day view's "Earlier today" fold has a
# real past item to collapse: every booking above sits on the dotted day
# (tomorrow), which left the Day view's <details> branch structurally present
# but never exercised. The lifecycle refuses past slots — NotInThePast guards
# :book AND :reschedule — but on a temporal resource "the past" is relative
# to the WRITE's instant: a booking made as of three hours ago for a slot two
# hours ago is legal, because at that instant the slot was in the future.
# (This is also why no Ash.Seed bypass is needed here anymore: the seed used
# to book this visit into tomorrow and then shove its slot back with the
# data layer's seeding helper; booking as of the same morning the slot sits
# in does the job through the attributed action, with its process instance
# and triage evaluation real.) On a reseed it already exists and is left
# alone (mix reset recreates the day from scratch, fold included).
earlier_today_at = fn ->
  now = DateTime.utc_now()
  candidate = now |> DateTime.add(-2 * 60 * 60) |> DateTime.truncate(:second)

  if DateTime.to_date(candidate) == Date.utc_today() do
    candidate
  else
    # A run just after midnight has no "two hours ago" inside today; the
    # day's first instant is still earlier than now, which is what counts.
    DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
  end
end

{:ok, biscuit_earlier_visit} =
  book.(biscuit, vet, %{
    scheduled_at: earlier_today_at.(),
    duration_minutes: 20,
    reason: "Ear infection recheck",
    severity: 2
  })

# ── Finance: the revenue demo's world ──────────────────────────────────────
#
# ~6 months of appointment history plus a live forward window, written
# through the attributed actions with as_of backdating — the same mechanic
# the walks below use, at volume. Every completion recognizes its charge at
# the completion's instant, so /revenue has months of real revenue to chart
# and the forecast has outcomes to learn rates from. Deterministic (fixed
# :rand seed) and idempotent (lookup-or-create, stage guards re-read the
# history): re-running backfills only the days that appeared since.
#
# BEFORE the story walks, deliberately — two reasons. The walks' roster and
# lanes are all this needs, and running first means the audit log's newest
# events are the story's own: /events reads newest-first, and a feed whose
# first page is the demo's narrative (instead of a wall of backfilled
# bookings) is the feed worth screenshotting.
#
# This runs before the compliance bundle is activated, like every walk:
# the first seeding's back-dated completions predate the bundle, and the
# finance walk's own discipline (weights recorded at patient creation,
# triage re-asserted in history) keeps any later top-up run lawful under
# the active bundle too.
ClinicDemo.FinanceSeeds.run()

# ── Walking visits through the process ─────────────────────────────────────
#
# Every appointment above already has an instance: booking started one (and
# every booking ran the triage decision, so the DMN evaluations pile up as
# they do in a real clinic). What follows moves several of them along, so
# the seeded data is not a row of identical cards: a full happy path ending
# in a discharge, a visit parked on the lab wait, a no-show, a cancellation,
# and one visit left standing at check-in.
#
# Nothing here reaches into the engine. Each step is a person completing the
# work item in front of them, and the process does the rest. On a re-run the
# visits have already moved, so each step fires only when the visit is still
# standing at the stage that makes it meaningful.

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

# Pepper: in, seen, written up — and the process discharges her at the end of
# the happy path, so `discharged_at` lands through the engine like everyone
# else's. The appointment's own stages are written into the history at spaced
# instants (the header note explains the re-assert at the end), and the work
# items still move at seed-run time: the engine's invoker sees each stage
# already taken and just advances the token.
pepper_visit = Scheduling.get_appointment!(pepper_visit.id)

if pepper_visit.status == :scheduled do
  record_triage_in_history.(pepper_visit, staff)

  pepper_visit = Scheduling.get_appointment!(pepper_visit.id)

  pepper_visit = Scheduling.get_appointment!(pepper_visit.id, as_of: checked_in_at)
  Scheduling.check_in_appointment!(pepper_visit, actor: staff, as_of: checked_in_at)

  pepper_visit = Scheduling.get_appointment!(pepper_visit.id)

  pepper_visit = Scheduling.get_appointment!(pepper_visit.id, as_of: completed_at)

  {:ok, _} =
    Scheduling.complete_appointment(
      pepper_visit,
      "Vaccinated against FVRCP and rabies. No adverse reaction observed.",
      actor: staff,
      as_of: completed_at
    )

  pepper_visit = Scheduling.get_appointment!(pepper_visit.id)

  # Re-assert the tail at the present, so the open version reads completed
  # and the engine's discharge below meets the status it guards on.
  Scheduling.check_in_appointment!(pepper_visit, actor: staff)
  pepper_visit = Scheduling.get_appointment!(pepper_visit.id)

  {:ok, _} =
    Scheduling.complete_appointment(
      pepper_visit,
      "Vaccinated against FVRCP and rabies. No adverse reaction observed.",
      actor: staff
    )

  pepper_visit = Scheduling.get_appointment!(pepper_visit.id)

  {:ok, _} =
    AshBpmn.complete_task(open_task.(pepper_visit, "CheckIn"),
      outcome: :arrived,
      actor: %{id: nurse.id}
    )

  {:ok, _} =
    AshBpmn.complete_task(open_task.(pepper_visit, "Consult"),
      outcome: :written_up,
      comment: "Nothing else to follow up.",
      actor: %{id: vet.id}
    )
end

# Clover: in, seen, bloods sent. This instance is parked on `AwaitLabResults`,
# which is the wait state, and it will stay there until somebody in the lab
# completes that task. Her stages ride the same spaced history as Pepper's,
# with the same present-tense re-assert (the walk ends on a back-dated write
# and there is no engine step after to take over the open version).
clover_visit = Scheduling.get_appointment!(clover_visit.id)

if clover_visit.status == :scheduled do
  record_triage_in_history.(clover_visit, staff)

  clover_visit = Scheduling.get_appointment!(clover_visit.id)

  clover_visit = Scheduling.get_appointment!(clover_visit.id, as_of: checked_in_at)
  Scheduling.check_in_appointment!(clover_visit, actor: staff, as_of: checked_in_at)

  clover_visit = Scheduling.get_appointment!(clover_visit.id)

  clover_notes = "Reduced gut sounds. Bloods sent; holding discharge until they are back."

  clover_visit = Scheduling.get_appointment!(clover_visit.id, as_of: completed_at)

  {:ok, _} =
    Scheduling.complete_appointment(clover_visit, clover_notes, actor: staff, as_of: completed_at)

  clover_visit = Scheduling.get_appointment!(clover_visit.id)

  Scheduling.check_in_appointment!(clover_visit, actor: staff)
  clover_visit = Scheduling.get_appointment!(clover_visit.id)
  {:ok, _} = Scheduling.complete_appointment(clover_visit, clover_notes, actor: staff)

  {:ok, _} =
    AshBpmn.complete_task(open_task.(clover_visit, "CheckIn"),
      outcome: :arrived,
      actor: %{id: nurse.id}
    )

  {:ok, _} =
    AshBpmn.complete_task(open_task.(clover_visit, "Consult"),
      outcome: :labs_pending,
      comment: "Biochem and PCV requested.",
      actor: %{id: tech.id}
    )
end

# Biscuit's dental follow-up: walked up to the write-up with the weight guard
# in mind — the weigh-in comes FIRST, so the check-in would pass the guard
# even with the bundle in force. The Consult task is left OPEN, so this visit
# sits completed-but-not-discharged: the exact row a Discharge click on the
# schedule/board wants, and one more token history for the instance viewer.
biscuit_dental =
  case appointment_by.(biscuit.id, "Dental cleaning follow-up") do
    nil ->
      {:ok, appointment} =
        book.(biscuit, vet, %{
          scheduled_at: tomorrow_at.(15),
          duration_minutes: 40,
          reason: "Dental cleaning follow-up",
          severity: 2
        })

      appointment

    appointment ->
      appointment
  end

biscuit_dental = Scheduling.get_appointment!(biscuit_dental.id)

if biscuit_dental.status == :scheduled do
  {:ok, _} = Scheduling.record_weight(biscuit, Decimal.new("11.8"), actor: staff)

  record_triage_in_history.(biscuit_dental, staff)

  biscuit_dental = Scheduling.get_appointment!(biscuit_dental.id)

  biscuit_dental = Scheduling.get_appointment!(biscuit_dental.id, as_of: checked_in_at)

  Scheduling.check_in_appointment!(biscuit_dental, actor: staff, as_of: checked_in_at)

  biscuit_dental = Scheduling.get_appointment!(biscuit_dental.id)

  dental_notes =
    "Scaling under sedation, no extractions needed. Discharging with soft-food advice."

  biscuit_dental = Scheduling.get_appointment!(biscuit_dental.id, as_of: completed_at)

  {:ok, _} =
    Scheduling.complete_appointment(biscuit_dental, dental_notes,
      actor: staff,
      as_of: completed_at
    )

  biscuit_dental = Scheduling.get_appointment!(biscuit_dental.id)

  Scheduling.check_in_appointment!(biscuit_dental, actor: staff)
  biscuit_dental = Scheduling.get_appointment!(biscuit_dental.id)

  {:ok, _} = Scheduling.complete_appointment(biscuit_dental, dental_notes, actor: staff)

  biscuit_dental = Scheduling.get_appointment!(biscuit_dental.id)

  {:ok, _} =
    AshBpmn.complete_task(open_task.(biscuit_dental, "CheckIn"),
      outcome: :arrived,
      actor: %{id: nurse.id}
    )
end

# Biscuit's nail trim: a no-show. The front desk closes the CheckIn task with
# the :no_show outcome, and the process routes the token through MarkNoShow —
# the machine transition lands exactly as it would from the board. The
# engine's write is a present-tense write, so it takes over the open version
# and no re-assert is needed; the history keeps the visit triaged and
# scheduled until seed-run time.
biscuit_no_show_visit = Scheduling.get_appointment!(biscuit_no_show_visit.id)

if biscuit_no_show_visit.status == :scheduled do
  record_triage_in_history.(biscuit_no_show_visit, staff)

  biscuit_no_show_visit = Scheduling.get_appointment!(biscuit_no_show_visit.id)

  {:ok, _} =
    AshBpmn.complete_task(open_task.(biscuit_no_show_visit, "CheckIn"),
      outcome: :no_show,
      comment: "Called twice, no answer.",
      actor: %{id: nurse.id}
    )
end

# Pepper's allergy recheck: cancelled before it happened, with the reason the
# cancellation surface shows. The cancel runs at seed-run time — its write
# takes over the open version, so the present reads cancelled and the
# history reads triaged-and-scheduled before that.
pepper_cancelled_visit = Scheduling.get_appointment!(pepper_cancelled_visit.id)

if pepper_cancelled_visit.status == :scheduled do
  record_triage_in_history.(pepper_cancelled_visit, staff)

  pepper_cancelled_visit = Scheduling.get_appointment!(pepper_cancelled_visit.id)

  {:ok, _} =
    Scheduling.cancel_appointment(pepper_cancelled_visit, "Owner is away; will rebook next month",
      actor: staff
    )
end

# ── The history's triage lane ──────────────────────────────────────────────
#
# One pass over every visit, re-asserting the triage the engine recorded at
# seed-run time at the history's instant instead — two hours back, an hour
# after the bookings. The board as of, say, ninety minutes ago then shows
# the booked-and-never-walked cards sitting in their triage lanes rather
# than all of them still in Booked. (The walked visits already had this done
# inside their walks; the temporal-read guard makes the pass a no-op for
# them and idempotent on reseed.)
#
# The story's visits only: the finance seeds run first now, and their visits
# carry a catalogue type (and manage their own triage at their own
# instants) — a future slot has no version at `triaged_at` to read, and a
# history slot needs no second opinion written at the story's hour.
story_appointments =
  Scheduling.list_appointments!()
  |> Enum.filter(&is_nil(&1.appointment_type_id))

for appointment <- story_appointments do
  record_triage_in_history.(appointment, staff)
end

{:ok, _} = Scheduling.record_weight(pepper, Decimal.new("4.35"), actor: staff)

waiting =
  ClinicDemo.Visits.HumanTask
  |> Ash.Query.for_read(:read)
  |> Ash.Query.filter(status in [:open, :claimed])
  |> Ash.read!()

appointments = Scheduling.list_appointments!()

discharged = Enum.count(appointments, & &1.discharged_at)

evaluation_count =
  ClinicDemo.Decisions.Evaluation
  |> Ash.Query.for_read(:read)
  |> Ash.read!(authorize?: false)
  |> length()

# The triage table lists the story's own visits — the no-type bookings the
# walks made — rather than every row the finance history backfilled around
# them (those all carry a catalogue type).
story_appointments =
  Enum.filter(appointments, &is_nil(&1.appointment_type_id))

# ── The judgment record ─────────────────────────────────────────────────────
#
# Every triage write above went through the `record_triage` action, whose
# admission hook keeps the judgment record in the same transaction (P4-S5):
# one append-only observation per judgment on the ledger, and the
# patient-acuity fact materialised off it citing that observation (C1's
# assertion active). A re-triaged patient's history is IN the facts table —
# period splits at each revision — not inferred from the appointments. The
# block below just says so: what the seed's triage answers left on the
# record, per story patient, oldest period first.

story_patient_ids = story_appointments |> Enum.map(& &1.patient_id) |> Enum.uniq()

judgment_observations =
  ClinicDemo.Judgments.Observation
  |> Ash.Query.for_read(:read)
  |> Ash.Query.filter(subject_id in ^story_patient_ids)
  |> Ash.read!(authorize?: false)

judgment_facts =
  ClinicDemo.Judgments.Fact
  |> Ash.Query.for_read(:read)
  |> Ash.Query.filter(subject_id in ^story_patient_ids)
  |> Ash.read!(authorize?: false)

now = DateTime.utc_now() |> DateTime.truncate(:second)

acuity_lines =
  Enum.map_join(story_patient_ids, "\n", fn patient_id ->
    subject = %{"type" => "ClinicDemo.Scheduling.Patient", "id" => patient_id}

    periods =
      judgment_facts
      |> Enum.filter(&(&1.subject == subject))
      |> Enum.sort_by(& &1.valid_at.lower, DateTime)

    current = Enum.find(periods, fn f -> DateTime.compare(f.valid_at.lower, now) != :gt end)

    "  #{patient_id |> Scheduling.get_patient!() |> Map.fetch!(:name)}: " <>
      "#{length(periods)} fact period(s), observations #{Enum.count(judgment_observations, &(&1.subject_id == patient_id))}" <>
      if(current, do: ", acuity now \"#{current.value}\"", else: ", no open period")
  end)

IO.puts("""

Judgment record (the story's triage answers, kept as facts):
  #{length(judgment_observations)} observations, #{length(judgment_facts)} acuity fact periods (story patients; the finance history keeps its own)
#{acuity_lines}
""")

IO.puts("""
Seeded:
  #{length(Scheduling.list_clinicians!())} clinicians
  #{length(Scheduling.list_patients!())} patients
  #{length(appointments)} appointments (#{discharged} discharged)
  #{length(waiting)} work items waiting: #{waiting |> Enum.map(& &1.node_id) |> Enum.sort() |> Enum.join(", ")}

Triage decided:
#{story_appointments |> Enum.map_join("\n", fn a -> "  #{a.reason} -> #{a.triage_urgency}" end)}
  #{evaluation_count} DMN triage evaluations on file
""")

# ── Compliance: put the appointment rule bundle in force ───────────────────
#
# Last, deliberately: everything above walked transitions the guard now
# watches (Clover has no recorded weight and could not be checked in under
# the activated bundle). The guard is inert until a bundle is active, which
# is what keeps a fresh database bootable and reseeding safe — the lifecycle
# itself short-circuits when an active bundle already exists.
#
# From here on, :check_in without a recorded patient weight is refused with
# the rule's gap text, and :complete without triage urgency is refused too.
# A REFUSAL files no evidence row by design — the compliance evaluation is
# recorded only for transitions that pass — so the seeded history contains
# no refusal row; the honest refusal is a live demo: try checking Clover in.

bundle = ClinicDemo.Compliance.activate_appointment_bundle!()

IO.puts("Compliance: clinic_appointment_rules in force (bundle #{bundle.content_hash}).")

# ── The value projection: the ledger's truth, folded once at seed end ──────
#
# BD-3: the walk produced the ledger; this one call folds it into the
# temporal `ValueProjection` rows `/revenue` reads. Idempotent — the
# checkpoint is the cursor — so a reseed (or a top-up run) drains only
# what is new. `/revenue` and the board now agree on the past by fold,
# and the equivalence test pins the two derivations together.
drained = ClinicDemo.BusinessEvents.ValueProjector.drain(:clinic)

IO.puts(
  "Value projection: folded #{drained} value events into #{ClinicDemo.BusinessEvents.ValueProjection} as of now."
)
