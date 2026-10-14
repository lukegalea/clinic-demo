defmodule ClinicDemo.FinanceSeeds do
  @moduledoc """
  The revenue demo's world: roughly six months of clinic history plus a
  live forward window, written entirely through the attributed actions —
  no `Ash.Seed`, no raw SQL — so every appointment, event and charge in the
  story is the real thing.

  Two stretches of time, and they are written differently on purpose:

    * **The history** (default ~26 weeks back) is back-dated with the
      temporal write form the board's time travel reads: a booking lands
      `as_of` three days before its slot, the triage answer ninety minutes
      before, the check-in at the slot itself, the write-up at the slot's
      end. `NotInThePast` measures "the past" from the write's own `as_of`,
      so a slot three months gone is in the write's future and the
      lifecycle accepts it. Each completion recognizes its charge at the
      completion's instant (the hook rides the write), so revenue-at-T is
      an as-of read with six months to look at.
    * **The live window** (next ~3 weeks) is booked at wall-now, statuses
      left `:scheduled` — the forecast's positive side: real future visits
      with catalogue prices, awaiting their outcomes.

  Three properties worth naming:

  **Deterministic.** Every visit's draws — patient, clinician, type, slot,
  outcome — come from a `:rand` stream seeded per visit from `(day, index)`
  alone, never from a shared stream's position. A conditional draw anywhere
  (a reseeded patient's weigh-in, a resumed visit's shortened walk) cannot
  shift the sequence for anything after it, so the same run-day rebuilds
  the same world byte for byte — which is what makes the /revenue
  screenshots comparable and the demo repeatable.

  **Idempotent.** Everything is lookup-or-create keyed on a natural value
  (the catalogue by name, patients by owner email, a visit by its patient
  and slot), and every lifecycle stage re-reads the history at its own
  instant before writing: the stage's own as-of read is the reseed guard,
  the same trick `priv/repo/seeds.exs` uses for triage. Re-running costs
  nothing and duplicates nothing — but the window slides with today, so a
  re-run months later backfills the days that have appeared since.

  **Presented honestly.** The seeds do not fake revenue: a charge exists
  only because a visit was walked to `:complete` through the guarded
  lifecycle, and the charge's amount is the catalogue price snapshotted at
  completion. The outcome mix (~85% completed, ~10% no-show, ~5%
  cancelled; weekdays ~14 visits, weekends ~5) is the shape the forecast's
  rates are computed from.

  Prerequisite: `ClinicDemo.Rules.install!/0` has run (booking starts a
  visit process), and `priv/repo/seeds.exs` has run for the clinician
  roster this module books against. Run as part of `mix seed`, or alone:

      mix run -e 'ClinicDemo.FinanceSeeds.run()'
  """

  require Ash.Query

  alias ClinicDemo.Scheduling

  # Any signed-in staff member will do; the demo has no authentication. The
  # id is a UUID because the process records who acted in uuid columns.
  @staff %{id: "00000000-0000-0000-0000-0000000000ab", role: :veterinarian}

  @defaults [
    weeks_back: 26,
    weeks_ahead: 3,
    weekday_per_day: 14,
    weekend_per_day: 5
  ]

  # The catalogue, with the weights the type mix draws from. Prices are the
  # story the revenue bars tell; after the first seeding the forecast reads
  # its completion rates from the history, never from this table.
  @catalogue [
    %{name: "Nail trim", base_price: "25", duration: 15, weight: 25},
    %{name: "Vaccination", base_price: "60", duration: 20, weight: 20},
    %{name: "Wellness exam", base_price: "75", duration: 30, weight: 25},
    %{name: "Dental cleaning", base_price: "320", duration: 60, weight: 10},
    %{name: "Surgery consult", base_price: "150", duration: 40, weight: 10},
    %{name: "Emergency visit", base_price: "220", duration: 45, weight: 10}
  ]

  # A fixed bench of patients and owners, so six months of visits reads as
  # a real client base returning, not two thousand strangers. Every animal
  # carries a date of birth on purpose: an unknown age is legal (the triage
  # table's age column matches neither band and the visit triages on its
  # signs), but the DMN engine's unary tests do not evaluate a null input —
  # a low-severity visit for an animal of unknown age would crash the
  # table's `"neonate", "senior"` cell. Real records have birthdates; so do
  # these.
  @patients [
    %{
      name: "Biscuit Jr.",
      species: :dog,
      breed: "Beagle",
      dob: ~D[2019-04-11],
      owner: "fin.biscuit@example.com"
    },
    %{
      name: "Mochi",
      species: :cat,
      breed: "Domestic Shorthair",
      dob: ~D[2024-02-20],
      owner: "fin.mochi@example.com"
    },
    %{
      name: "Rufus",
      species: :dog,
      breed: "Labrador",
      dob: ~D[2014-08-02],
      owner: "fin.rufus@example.com"
    },
    %{
      name: "Clementine",
      species: :cat,
      breed: "Ragdoll",
      dob: ~D[2021-11-15],
      owner: "fin.clementine@example.com"
    },
    %{
      name: "Ziggy",
      species: :rabbit,
      breed: nil,
      dob: ~D[2026-06-01],
      owner: "fin.ziggy@example.com"
    },
    %{
      name: "Bruno",
      species: :dog,
      breed: "Boxer",
      dob: ~D[2016-03-30],
      owner: "fin.bruno@example.com"
    },
    %{
      name: "Waffle",
      species: :dog,
      breed: "Corgi",
      dob: ~D[2025-12-05],
      owner: "fin.waffle@example.com"
    },
    %{
      name: "Nori",
      species: :cat,
      breed: "Bengal",
      dob: ~D[2023-07-19],
      owner: "fin.nori@example.com"
    },
    %{
      name: "Pickle",
      species: :rabbit,
      breed: nil,
      dob: ~D[2020-01-08],
      owner: "fin.pickle@example.com"
    },
    %{
      name: "Ada",
      species: :dog,
      breed: "Poodle",
      dob: ~D[2012-05-22],
      owner: "fin.ada@example.com"
    },
    %{
      name: "Truffle",
      species: :cat,
      breed: "British Shorthair",
      dob: ~D[2018-09-14],
      owner: "fin.truffle@example.com"
    },
    %{
      name: "Gus",
      species: :dog,
      breed: "Greyhound",
      dob: ~D[2015-10-31],
      owner: "fin.gus@example.com"
    }
  ]

  @reasons [
    "Annual checkup",
    "Limping since the weekend",
    "Vaccines due",
    "Itchy ears again",
    "Dental scale and polish",
    "Off her food",
    "Nail trim",
    "Lump on the left flank",
    "Weight check",
    "Sore eye, half closed",
    "Follow-up on the antibiotics",
    "Coughing at night"
  ]

  @notes [
    "Bright, alert and responsive. Procedure tolerated well; discharged with home-care advice.",
    "Physical exam unremarkable. Owner questions answered; recheck only if signs return.",
    "Tartar noted on upper molars. Discharged with soft-food advice and a dental follow-up plan.",
    "Vaccination given subcutaneously, no adverse reaction observed. Next due in twelve months.",
    "Nails trimmed short of the quick. Minor scuffing on the rear pads, nothing actionable.",
    "Weight trending up slightly. Diet conversation had; recheck weight in eight weeks.",
    "Ear cytology taken. Discharged with drops; owner to return if the head-shaking persists.",
    "Lump is soft and movable, likely a lipoma. Measured and noted; monitor for change.",
    "Eye staining clean. Discharged with lubricant; keep the pawing in check with a collar.",
    "Mild dental gingivitis. Antibiotics dispensed; rebook a scale under sedation if it worsens."
  ]

  @cancel_reasons [
    "Owner is away; will rebook",
    "Double-booked at work",
    "Weather — roads are bad",
    "Pet is acting normal again",
    "Car trouble, sorry"
  ]

  @doc """
  Seeds the finance demo world. Options (all optional):

    * `:weeks_back` — how deep the history goes (default 26).
    * `:weeks_ahead` — how wide the live window is (default 3).
    * `:weekday_per_day` / `:weekend_per_day` — average visits per day;
      each day draws a volume around its average, not a flat count.

  Returns a stats map (booked/skipped appointments, outcomes walked).
  """
  def run(opts \\ []) do
    opts = Keyword.merge(@defaults, opts)

    types = seed_catalogue()
    patients = seed_patients()
    clinicians = seed_roster()

    ctx = %{
      types: types,
      patients: patients,
      clinicians: clinicians,
      existing: load_existing(),
      base: Keyword.take(opts, [:weekday_per_day, :weekend_per_day])
    }

    history_days =
      for offset <- (opts[:weeks_back] * 7)..1//-1, do: Date.add(Date.utc_today(), -offset)

    future_days =
      for offset <- 1..(opts[:weeks_ahead] * 7), do: Date.add(Date.utc_today(), offset)

    {_ctx, stats} =
      Enum.reduce(history_days, {ctx, blank_stats()}, fn day, {ctx, stats} ->
        walk_day(day, stats, ctx, :history)
      end)

    {_ctx, stats} =
      Enum.reduce(future_days, {ctx, stats}, fn day, {ctx, stats} ->
        walk_day(day, stats, ctx, :future)
      end)

    print(stats, opts)
    stats
  end

  # --- the catalogue ------------------------------------------------------------

  defp seed_catalogue do
    Enum.map(@catalogue, fn entry ->
      type =
        ClinicDemo.Scheduling.AppointmentType
        |> Ash.Query.filter(name == ^entry.name)
        |> Ash.read_one!(authorize?: false)
        |> case do
          nil ->
            ClinicDemo.Scheduling.AppointmentType
            |> Ash.Changeset.for_create(:create, %{
              name: entry.name,
              base_price: Decimal.new(entry.base_price),
              default_duration_minutes: entry.duration
            })
            |> Ash.create!(authorize?: false)

          type ->
            type
        end

      {entry, type}
    end)
  end

  # --- patients -------------------------------------------------------------------

  defp seed_patients do
    Enum.map(@patients, fn entry ->
      ClinicDemo.Scheduling.Patient
      |> Ash.Query.filter(owner_email == ^entry.owner)
      |> Ash.read_one!(authorize?: false)
      |> case do
        nil ->
          {:ok, patient} =
            Scheduling.register_patient(
              %{
                name: entry.name,
                species: entry.species,
                breed: entry.breed,
                date_of_birth: entry.dob,
                owner_email: entry.owner
              },
              actor: @staff
            )

          # A recorded weight, so the walk's check-ins pass the compliance
          # weight guard on top-up runs that land after the bundle is in
          # force.
          Scheduling.record_weight(
            patient,
            Decimal.div(Decimal.new(ranged(200, 600)), Decimal.new(10)),
            actor: @staff
          )

          patient

        patient ->
          patient
      end
    end)
  end

  # --- the roster -------------------------------------------------------------------

  # Books against the roster `priv/repo/seeds.exs` stood up. Vets take the
  # lion's share of slots, techs most of the rest, nurses what remains —
  # drawn by weighted index over the name-sorted roster, so the assignment
  # is stable across runs.
  defp seed_roster do
    roster =
      Scheduling.list_clinicians!(authorize?: false)
      |> Enum.filter(& &1.active)
      |> Enum.sort_by(& &1.full_name)

    if roster == [] do
      raise """
      no active clinicians on the roster — FinanceSeeds books against the
      roster priv/repo/seeds.exs stands up. Run `mix seed` (which does both,
      in order) before running this module alone.
      """
    end

    roster
  end

  defp pick_clinician(roster) do
    by_role = Enum.group_by(roster, & &1.role)

    pool =
      cond do
        uniform_real() < 0.55 and Map.has_key?(by_role, :veterinarian) ->
          by_role.veterinarian

        uniform_real() < 0.70 and Map.has_key?(by_role, :technician) ->
          by_role.technician

        Map.has_key?(by_role, :nurse) ->
          by_role.nurse

        true ->
          roster
      end

    Enum.fetch!(pool, ranged(1, length(pool)) - 1)
  end

  # --- the day walk --------------------------------------------------------------------

  defp walk_day(day, stats, ctx, mode) do
    base =
      if Date.day_of_week(day) in 1..5,
        do: ctx.base[:weekday_per_day],
        else: ctx.base[:weekend_per_day]

    count = day_volume(day, base)

    Enum.reduce(1..count, {ctx, stats}, fn index, {ctx, stats} ->
      walk_visit(day, index, ctx, stats, mode)
    end)
  end

  defp walk_visit(day, index, ctx, stats, mode) do
    # The visit's own stream: seeded from the day and the visit's position
    # in it, and from nothing else. A re-run (or a resume) draws the same
    # patient, slot and type again, which is exactly what the lookup-or-
    # create contract needs — the existence check keys on what was drawn,
    # so it must be the drawing that is stable, not the stream position.
    :rand.seed(:exsss, visit_seed(day, index))

    patient = Enum.fetch!(ctx.patients, ranged(1, length(ctx.patients)) - 1)
    clinician = pick_clinician(ctx.clinicians)
    {_entry, type} = weighted_pick(ctx.types, fn {entry, _type} -> entry.weight end)

    slot = DateTime.new!(day, slot_time(), "Etc/UTC")

    case Map.get(ctx.existing, {patient.id, slot}) do
      nil ->
        appointment = book(patient, clinician, type, slot, mode)
        ctx = put_existing(ctx, patient.id, slot, appointment)

        case mode do
          :future ->
            # Stays scheduled — the forecast's raw material.
            {ctx, bump(stats, :booked)}

          :history ->
            outcome = roll_outcome()
            {ctx, walk_outcome(appointment, outcome, slot, bump(stats, :booked))}
        end

      # Already on file and already finished: the cheapest skip, no
      # temporal reads at all. (The status here is the PRESENT's, read in
      # the one bulk load — a terminal present means the walk completed.)
      %ClinicDemo.Scheduling.Appointment{status: status}
      when status in [:completed, :cancelled, :no_show] ->
        {ctx, bump(stats, :skipped)}

      appointment ->
        # Booked but unfinished (a previous run died mid-walk): resume
        # whatever the history is missing, deriving the outcome from where
        # the visit stands rather than re-rolling it.
        case mode do
          :future ->
            {ctx, bump(stats, :skipped)}

          :history ->
            outcome = outcome_of(appointment)
            {ctx, walk_outcome(appointment, outcome, slot, bump(stats, :skipped))}
        end
    end
  end

  # Booking: the real action. History slots are back-dated — `as_of` three
  # days before the slot, so the slot is in the write's future, which is the
  # whole trick. Live-window slots are booked at wall-now, `as_of` unset:
  # back-dating one would put the write's instant AHEAD of the wall clock
  # for any slot less than three days out, and the visit's period would
  # start in the future — invisible to every present-tense read, the
  # engine's own subject load included. Booking starts the visit process (a
  # present-tense side effect; the engine is not temporal, see
  # priv/repo/seeds.exs's header).
  defp book(patient, clinician, type, slot, mode) do
    attrs = %{
      patient_id: patient.id,
      clinician_id: clinician.id,
      appointment_type_id: type.id,
      scheduled_at: slot,
      duration_minutes: type.default_duration_minutes,
      reason: Enum.fetch!(@reasons, ranged(1, length(@reasons)) - 1),
      severity: Enum.fetch!([1, 1, 2, 2, 2, 3, 3, 4], ranged(1, 8) - 1)
    }

    opts =
      case mode do
        :history ->
          booked_as_of =
            slot
            |> DateTime.add(-3 * 24 * 3600 - ranged(0, 8) * 3600, :second)
            |> DateTime.truncate(:second)

          [actor: @staff, as_of: booked_as_of]

        :future ->
          [actor: @staff]
      end

    Scheduling.book_appointment(attrs, opts)
    |> case do
      {:ok, appointment} ->
        appointment

      {:error, error} ->
        raise "finance seed booking failed for slot #{DateTime.to_iso8601(slot)}: #{inspect(error)}"
    end
  end

  # The lifecycle behind the slot, one guarded stage at a time. Every stage
  # re-reads the history at its own instant first, so a re-run resumes
  # instead of refusing or duplicating.
  defp walk_outcome(appointment, :completed, slot, stats) do
    triage_in_history(appointment, slot)

    unless_history_is?(appointment, slot, [:checked_in, :completed], fn version ->
      Scheduling.check_in_appointment!(version, actor: @staff, as_of: slot)
    end)

    complete_at = DateTime.add(slot, 30 * 60, :second) |> DateTime.truncate(:second)
    notes = Enum.fetch!(@notes, ranged(1, length(@notes)) - 1)

    unless_history_is?(appointment, complete_at, [:completed], fn version ->
      Scheduling.complete_appointment!(version, notes, actor: @staff, as_of: complete_at)
    end)

    # The re-assert: the back-dated walk splits everything before the
    # engine's wall-clock triage write, so the OPEN version still reads
    # scheduled. Replay the tail at the present, so the board and the day
    # view read the visit as it ended — and the engine's token advance
    # meets the status it expects. The charge exists already (it rode the
    # back-dated completion), and the hook's one-charge-per-visit check
    # keeps the replay from recognizing anything twice.
    open = Scheduling.get_appointment!(appointment.id)

    if open.status == :scheduled do
      Scheduling.check_in_appointment!(open, actor: @staff)
      open = Scheduling.get_appointment!(appointment.id)
      Scheduling.complete_appointment!(open, notes, actor: @staff)
      close_tasks(appointment.id)
    end

    bump(stats, :completed)
  end

  defp walk_outcome(appointment, :cancelled, slot, stats) do
    triage_in_history(appointment, slot)

    cancel_at = DateTime.add(slot, -2 * 3600, :second) |> DateTime.truncate(:second)
    reason = Enum.fetch!(@cancel_reasons, ranged(1, length(@cancel_reasons)) - 1)

    unless_history_is?(appointment, cancel_at, [:cancelled], fn version ->
      Scheduling.cancel_appointment!(version, reason, actor: @staff, as_of: cancel_at)
    end)

    open = Scheduling.get_appointment!(appointment.id)

    if open.status == :scheduled do
      Scheduling.cancel_appointment!(open, reason, actor: @staff)
    end

    bump(stats, :cancelled)
  end

  # No-shows are written the way the main seeds write theirs: the front
  # desk closes the CheckIn work item with the :no_show outcome and the
  # ENGINE performs the transition, at wall-now. Back-dating one would
  # strand the engine's own write behind a status that had already moved.
  defp walk_outcome(appointment, :no_show, slot, stats) do
    triage_in_history(appointment, slot)

    open = Scheduling.get_appointment!(appointment.id)

    if open.status == :scheduled do
      close_task(appointment.id, "CheckIn", :no_show)
    end

    bump(stats, :no_show)
  end

  # Where a resumed visit already stands, derived from its present rather
  # than re-rolled: terminal states speak for themselves; a past slot still
  # standing scheduled in the present resumes as a no-show — completing it
  # on a guess (notes invented after the fact) is not a seed's call.
  defp outcome_of(appointment) do
    appointment = Scheduling.get_appointment!(appointment.id)

    case appointment.status do
      :completed -> :completed
      :cancelled -> :cancelled
      :no_show -> :no_show
      _other -> :no_show
    end
  end

  # The triage answer the engine recorded at booking time, re-asserted at
  # the history's instant — the same move as the main seeds. The board as
  # of any past instant then shows the visit in its triage lane, and a
  # top-up walk under an active compliance bundle finds the facts the
  # guard reads.
  defp triage_in_history(appointment, slot) do
    open = Scheduling.get_appointment!(appointment.id)

    if urgency = open.triage_urgency do
      triaged_at = DateTime.add(slot, -90 * 60, :second) |> DateTime.truncate(:second)

      version = Scheduling.get_appointment!(appointment.id, as_of: triaged_at)

      if is_nil(version.triage_urgency) do
        Scheduling.record_appointment_triage!(version, urgency, actor: @staff, as_of: triaged_at)
      end
    end
  end

  defp unless_history_is?(appointment, at, statuses, write) do
    version = Scheduling.get_appointment!(appointment.id, as_of: at)

    unless version.status in statuses do
      write.(version)
    end
  end

  # --- engine work items -----------------------------------------------------------------

  # Completed visits: close the CheckIn item (arrived) and the Consult item
  # (written up); the engine advances the token through discharge. Tasks
  # are read open-or-claimed only — completed task reads are not safe to
  # load (the usage rules' rule 20).
  defp close_tasks(appointment_id) do
    close_task(appointment_id, "CheckIn", :arrived)
    close_task(appointment_id, "Consult", :written_up)
  end

  defp close_task(appointment_id, node_id, outcome) do
    case find_open_task(appointment_id, node_id) do
      nil ->
        # The work item already moved (a resumed visit) — nothing to close.
        :ok

      task ->
        AshBpmn.complete_task(task, outcome: outcome, actor: %{id: task_actor(node_id)})
    end
  end

  defp find_open_task(appointment_id, node_id) do
    ClinicDemo.Visits.HumanTask
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(node_id == ^node_id and status in [:open, :claimed])
    |> Ash.read!(authorize?: false)
    |> Enum.find(fn task ->
      Ash.get!(ClinicDemo.Visits.Instance, task.instance_id, authorize?: false).subject_id ==
        appointment_id
    end)
  end

  defp task_actor("CheckIn"), do: front_desk_id()
  defp task_actor(_consult), do: @staff.id

  defp front_desk_id do
    Scheduling.list_clinicians!(authorize?: false)
    |> Enum.find(&(&1.role == :nurse and &1.active))
    |> case do
      nil -> @staff.id
      nurse -> nurse.id
    end
  end

  # --- draws -------------------------------------------------------------------------------

  # A visit's own seed state, derived from the day and the visit's position
  # alone. Three integers, off a hash of the coordinates: stable across
  # runs and processes, and independent of how many draws any other visit
  # happened to make.
  defp visit_seed(day, index) do
    <<a::32, b::32, c::32, _::binary>> =
      :erlang.md5(:erlang.term_to_binary({Date.to_iso8601(day), index, "clinic-demo-finance"}))

    {a, b, c}
  end

  # A day's volume, drawn from the day's own stream (so a day's count does
  # not depend on how many visits the previous day made): core plus jitter
  # reads as busy days and slow days, not a metronome.
  defp day_volume(day, base) do
    :rand.seed(:exsss, visit_seed(day, 0))
    core = div(base, 2)
    jitter = ranged(0, base - core + 2)
    max(1, core + jitter)
  end

  # Draw an integer in min..max off the seeded :rand stream.
  defp ranged(min, max) when max >= min, do: min + :rand.uniform(max - min + 1) - 1

  defp uniform_real, do: :rand.uniform()

  defp weighted_pick(items, weight_of) do
    total = items |> Enum.map(weight_of) |> Enum.sum()
    roll = uniform_real() * total

    {found, _} =
      Enum.reduce(items, {nil, 0}, fn item, {found, acc} ->
        acc = acc + weight_of.(item)

        cond do
          not is_nil(found) -> {found, acc}
          roll <= acc -> {item, acc}
          true -> {nil, acc}
        end
      end)

    # The float roll can land a hair past the total; the heaviest entry is
    # the honest fallback.
    found || Enum.max_by(items, weight_of)
  end

  # ~10% no-show, ~5% cancelled, the rest completed — the folklore the
  # history is drawn with, one independent roll per visit.
  defp roll_outcome do
    roll = uniform_real()

    cond do
      roll < 0.10 -> :no_show
      roll < 0.15 -> :cancelled
      true -> :completed
    end
  end

  # A slot between 08:00 and 17:30 on quarter hours.
  defp slot_time do
    minutes = ranged(0, 38) * 15
    Time.add(~T[08:00:00], minutes * 60, :second)
  end

  # --- bookkeeping -------------------------------------------------------------------------

  defp load_existing do
    ClinicDemo.Scheduling.Appointment
    |> Ash.Query.select([:id, :patient_id, :scheduled_at, :status])
    |> Ash.read!(authorize?: false)
    |> Map.new(&{{&1.patient_id, &1.scheduled_at}, &1})
  end

  defp put_existing(ctx, patient_id, slot, appointment) do
    Map.update!(ctx, :existing, fn existing ->
      Map.put(existing, {patient_id, slot}, appointment)
    end)
  end

  defp blank_stats, do: %{booked: 0, skipped: 0, completed: 0, cancelled: 0, no_show: 0}

  defp bump(stats, key), do: Map.update!(stats, key, &(&1 + 1))

  defp print(stats, opts) do
    IO.puts("""
    Finance seeds:
      window: #{opts[:weeks_back]} weeks back, #{opts[:weeks_ahead]} weeks ahead
      appointments booked: #{stats.booked} (#{stats.skipped} already on file)
      outcomes walked: #{stats.completed} completed, #{stats.cancelled} cancelled, #{stats.no_show} no-show
    """)
  end
end
