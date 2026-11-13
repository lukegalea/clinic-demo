defmodule ClinicDemo.Planning.Reader do
  @moduledoc """
  The weekly roster's declared inputs, read through the domain's own read
  actions.

  `read/2` returns the facts a plan about one Monday-to-Sunday UTC week is built
  from, **as they were at `cutoff`**:

    * **appointments** — `Appointment` rows with `status == :scheduled` whose
      slot starts in the week. `Appointment` is temporal, so this read is `as_of`
      the cutoff: the schedule as the clinic knew it then. The solver never
      moves one; they are the demand the roster must cover.
    * **availability** — `Availability` rows (temporal, read `as_of` the cutoff)
      for the week. `available: false` windows are what the roster cannot use.
    * **clinicians** and **shift templates** — the active roster and the
      patterns it may work. Neither is temporal, so a change to either is caught
      by its content hash at apply time rather than by an as-of read.
    * **applied shifts and assignments** — the `Shift` and `Assignment` rows a
      person already applied for the week (`state == :scheduled`). They are the
      previously applied plan a replan preserves where it can.

  Every fact carries what the snapshot records as its source: a resource, an id
  and a `version_number` (for a temporal row the start of the period read, in
  microseconds, so a revision is a new version) plus a content hash of the values
  the plan depends on. `inputs/1` turns the facts into the snapshot's inputs.

  This module does I/O and nothing else. Turning facts into the model's data is
  `ClinicDemo.Planning.Lowering`; the independent check of a candidate reads the
  facts directly and shares no code with that lowering.
  """

  require Ash.Query

  alias AshOpenLineage.Snapshot.CanonicalJSON
  alias AshOpenLineage.Snapshot.Input
  alias ClinicDemo.Planning.Machinery
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Scheduling.{Assignment, Availability, Clinician, Shift, ShiftTemplate}

  @appointment "ClinicDemo.Scheduling.Appointment"
  @availability "ClinicDemo.Scheduling.Availability"
  @clinician "ClinicDemo.Scheduling.Clinician"
  @template "ClinicDemo.Scheduling.ShiftTemplate"
  @shift "ClinicDemo.Scheduling.Shift"
  @assignment "ClinicDemo.Scheduling.Assignment"

  @type facts :: %{
          optional(:policy) => map(),
          week_start: Date.t(),
          effective_at: DateTime.t(),
          horizon_end: DateTime.t(),
          clinicians: [map()],
          templates: [map()],
          availabilities: [map()],
          appointments: [map()],
          shifts: [map()],
          assignments: [map()]
        }

  @doc "The instant a Monday-anchored week starts: 00:00 UTC."
  @spec week_start_at(Date.t()) :: DateTime.t()
  def week_start_at(%Date{} = week_start), do: DateTime.new!(week_start, ~T[00:00:00], "Etc/UTC")

  @doc """
  Reads the facts for the week starting `week_start` (a Monday), `as_of` `cutoff`
  for the temporal resources.
  """
  @spec read(Date.t(), DateTime.t()) :: facts()
  def read(%Date{} = week_start, %DateTime{} = cutoff) do
    from = week_start_at(week_start)
    to = DateTime.add(from, 7 * 86_400, :second)
    # `as_of` is a property of the query: pinned here, before the read, so the
    # temporal resource answers with the versions valid at the cutoff.
    appointments =
      Scheduling.Appointment
      |> Ash.Query.for_read(:in_window, %{from: from, to: to})
      |> Ash.Query.as_of(cutoff)
      |> Ash.Query.filter(status == :scheduled)
      |> Ash.Query.load(:appointment_type)
      |> Ash.read!(actor: Machinery.actor())
      |> Enum.map(&appointment/1)

    availabilities =
      Availability
      |> Ash.Query.as_of(cutoff)
      |> Ash.Query.filter(starts_at >= ^from and starts_at < ^to)
      |> Ash.read!(actor: Machinery.actor())
      |> Enum.map(&availability/1)

    appointment_ids = Enum.map(appointments, & &1.id)

    %{
      week_start: week_start,
      effective_at: from,
      horizon_end: to,
      clinicians: clinicians(),
      templates: templates(),
      availabilities: availabilities,
      appointments: Enum.sort_by(appointments, & &1.id),
      shifts: shifts(from, to),
      assignments: assignments(appointment_ids)
    }
  end

  @doc """
  The snapshot inputs for `facts`, sorted by key. An appointment that cannot be
  planned as it stands (it crosses UTC midnight, which a day-shift roster cannot
  cover) is an `:invalid` input, which makes the run `:needs_input` naming it.
  """
  @spec inputs(facts()) :: [Input.t()]
  def inputs(facts) do
    appointments =
      for a <- facts.appointments do
        input(
          "appointment:#{a.id}",
          :appointment,
          @appointment,
          a,
          appointment_status(a),
          appointment_hash(a)
        )
      end

    availabilities =
      for a <- facts.availabilities do
        input(
          "availability:#{a.id}",
          :availability,
          @availability,
          a,
          :value,
          availability_hash(a)
        )
      end

    clinicians =
      for c <- facts.clinicians do
        input("clinician:#{c.id}", :clinician, @clinician, c, :value, hash(%{role: c.role}))
      end

    templates =
      for t <- facts.templates do
        input("template:#{t.id}", :template, @template, t, :value, template_hash(t))
      end

    shifts =
      for s <- facts.shifts do
        input("shift:#{s.id}", :applied_shift, @shift, s, :value, shift_hash(s))
      end

    assignments =
      for a <- facts.assignments do
        input(
          "assignment:#{a.id}",
          :applied_assignment,
          @assignment,
          a,
          :value,
          hash(%{appointment_id: a.appointment_id, clinician_id: a.clinician_id})
        )
      end

    Enum.sort_by(
      appointments ++ availabilities ++ clinicians ++ templates ++ shifts ++ assignments,
      &{&1.key, &1.role}
    )
  end

  @doc "Content hash (lowercase hex SHA-256) of any JSON-encodable term."
  @spec hash(term()) :: String.t()
  def hash(term),
    do: :crypto.hash(:sha256, CanonicalJSON.encode!(term)) |> Base.encode16(case: :lower)

  # ── rows -> facts ──────────────────────────────────────────────────────────

  defp appointment(row) do
    ends_at = DateTime.add(row.scheduled_at, row.duration_minutes * 60, :second)

    %{
      id: row.id,
      starts_at: row.scheduled_at,
      booked_minutes: row.duration_minutes,
      ends_at: ends_at,
      booked_clinician_id: row.clinician_id,
      type_name: row.appointment_type && row.appointment_type.name,
      urgency: row.triage_urgency,
      version: version_number(row)
    }
  end

  defp availability(row) do
    %{
      id: row.id,
      clinician_id: row.clinician_id,
      starts_at: row.starts_at,
      ends_at: row.ends_at,
      available: row.available,
      version: version_number(row)
    }
  end

  defp clinicians do
    Clinician
    |> Ash.Query.filter(active == true)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(actor: Machinery.actor())
    |> Enum.map(&%{id: &1.id, role: &1.role, version: 0})
  end

  defp templates do
    ShiftTemplate
    |> Ash.Query.filter(active == true)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(actor: Machinery.actor())
    |> Enum.map(fn t ->
      %{
        id: t.id,
        name: t.name,
        role: t.role,
        from_minute: t.start_offset_minutes,
        to_minute: t.end_offset_minutes,
        days: Enum.sort(t.allowed_days),
        version: 0
      }
    end)
  end

  defp shifts(from, to) do
    Shift
    |> Ash.Query.filter(state == :scheduled and starts_at >= ^from and starts_at < ^to)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(actor: Machinery.actor())
    |> Enum.map(fn s ->
      %{
        id: s.id,
        clinician_id: s.clinician_id,
        role: s.role,
        starts_at: s.starts_at,
        ends_at: s.ends_at,
        shift_template_id: s.shift_template_id,
        version: 0
      }
    end)
  end

  # Only assignments for appointments that are still demand: an assignment for a
  # visit that has since left the schedule is history, not a plan to preserve.
  defp assignments([]), do: []

  defp assignments(appointment_ids) do
    Assignment
    |> Ash.Query.filter(state == :scheduled and appointment_id in ^appointment_ids)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(actor: Machinery.actor())
    |> Enum.map(
      &%{
        id: &1.id,
        appointment_id: &1.appointment_id,
        clinician_id: &1.clinician_id,
        role: &1.role,
        version: 0
      }
    )
  end

  # ── snapshot inputs ────────────────────────────────────────────────────────

  defp input(key, role, resource, fact, status, content_hash) do
    %Input{
      key: key,
      role: role,
      status: status,
      source: %{resource: resource, id: fact.id, version_number: fact.version},
      content_hash: content_hash
    }
  end

  defp appointment_status(%{starts_at: starts_at} = appointment) do
    ends_at = Map.get(appointment, :planned_ends_at, appointment.ends_at)

    if DateTime.to_date(starts_at) == DateTime.to_date(DateTime.add(ends_at, -1, :second)),
      do: :value,
      else: :invalid
  end

  defp appointment_hash(a) do
    hash(%{
      starts_at: a.starts_at,
      booked_minutes: a.booked_minutes,
      booked_clinician_id: a.booked_clinician_id,
      type_name: a.type_name,
      urgency: a.urgency && Atom.to_string(a.urgency)
    })
  end

  defp availability_hash(a) do
    hash(%{
      clinician_id: a.clinician_id,
      starts_at: a.starts_at,
      ends_at: a.ends_at,
      available: a.available
    })
  end

  defp template_hash(t) do
    hash(%{
      name: t.name,
      role: Atom.to_string(t.role),
      from_minute: t.from_minute,
      to_minute: t.to_minute,
      days: t.days
    })
  end

  defp shift_hash(s) do
    hash(%{
      clinician_id: s.clinician_id,
      role: Atom.to_string(s.role),
      starts_at: s.starts_at,
      ends_at: s.ends_at
    })
  end

  @doc """
  A temporal row's version number: when its period starts, in microseconds, so any
  revision (or a replacement) opens a later period and the number moves; 0 for a row
  that is not temporal.
  """
  @spec version_number(map()) :: non_neg_integer()
  def version_number(%{valid_at: %{lower: %DateTime{} = lower}}),
    do: DateTime.to_unix(lower, :microsecond)

  def version_number(_row), do: 0
end
