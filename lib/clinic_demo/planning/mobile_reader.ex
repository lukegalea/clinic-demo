defmodule ClinicDemo.Planning.MobileReader do
  @moduledoc """
  The mobile-visits plan's declared inputs, read through the domain's own read
  actions.

  `read/4` returns the facts a plan about **one veterinarian's one UTC day** is
  built from, as they were at `cutoff`:

    * **visits** — the day's `VisitRequest`s (temporal, read `as_of` the cutoff)
      that are `:requested`, or `:scheduled` onto this veterinarian. A scheduled
      request carries the start its booked appointment has, which a replan prefers
      to keep. A visit that cannot be planned as it stands (its appointment type is
      not mobile-capable; the kit does not carry the equipment it needs; its booked
      appointment is gone) is an `:invalid` input, which makes the run
      `:needs_input` naming it.
    * **commitments** — what the veterinarian is already doing, **pinned** in time
      and place: scheduled `Appointment`s (temporal, `as_of` the cutoff) they
      attend, in the clinic or at a mobile location. Who attends is the applied
      `Assignment` if the weekly roster placed one, otherwise the booked clinician:
      the same calendar the roster composes. The visit requests' own appointments
      are not commitments (they are what is being planned). A commitment that
      overlaps another commitment or blocked time is `:invalid` (`commitment_overlap`).
    * **blocked time** — `Availability` removed for the veterinarian and telehealth
      appointments they attend: no service and no travel may overlap it.
    * **the working window** — the veterinarian's applied `Shift` for the day when
      the roster placed one, otherwise 08:00-18:00 UTC; widened to hold every
      commitment.
    * **the travel matrix** — the latest `TravelMatrix` version of the plan's key
      published by the cutoff, its content hash recomputed (a row edited behind the
      resource's back is `:invalid`, `matrix_hash_mismatch`). A pair the plan needs
      that the matrix does not hold is an `:unresolved` input naming the pair
      (`travel_pair:<from>:<to>`), never a zero. An unreachable pair is data: the
      model refuses it.

  Every fact carries what the snapshot records as its source: a resource, an id and
  a `version_number` plus a content hash of the values the plan depends on;
  `inputs/1` turns the facts into the snapshot's inputs. This module does I/O and
  nothing else: turning facts into the model's data is
  `ClinicDemo.Planning.MobileLowering`, and the independent check reads the
  domain-level problem and shares no code with it.
  """

  require Ash.Query

  alias AshOpenLineage.Snapshot.Input
  alias ClinicDemo.Planning.{Machinery, Reader}

  alias ClinicDemo.Scheduling.{
    Appointment,
    Assignment,
    Availability,
    Clinician,
    ServiceLocation,
    Shift,
    TravelMatrix,
    VisitRequest
  }

  @default_work_from_minute 8 * 60
  @default_work_to_minute 18 * 60

  @appointment "ClinicDemo.Scheduling.Appointment"
  @assignment "ClinicDemo.Scheduling.Assignment"
  @availability "ClinicDemo.Scheduling.Availability"
  @clinician "ClinicDemo.Scheduling.Clinician"
  @location "ClinicDemo.Scheduling.ServiceLocation"
  @matrix "ClinicDemo.Scheduling.TravelMatrix"
  @shift "ClinicDemo.Scheduling.Shift"
  @visit_request "ClinicDemo.Scheduling.VisitRequest"

  @doc "The default working window, in minutes after UTC midnight."
  @spec default_work_window() :: {non_neg_integer(), non_neg_integer()}
  def default_work_window, do: {@default_work_from_minute, @default_work_to_minute}

  @doc """
  Reads the facts for `clinician_id` on `day`, `as_of` `cutoff` for the temporal
  resources. Option: `:matrix_key` (default `"clinic_van"`). The veterinarian starts
  and ends the day at the clinic.

  `{:error, reason}` when the plan has no veterinarian (`:clinician_unavailable`) or
  no clinic to start from (`:no_clinic_location`).
  """
  @spec read(Date.t(), Ecto.UUID.t(), DateTime.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def read(%Date{} = day, clinician_id, %DateTime{} = cutoff, opts \\ []) do
    from = Reader.week_start_at(day)
    to = DateTime.add(from, 86_400, :second)
    matrix_key = Keyword.get(opts, :matrix_key, "clinic_van")

    with {:ok, clinician} <- clinician(clinician_id),
         {:ok, clinic} <- clinic() do
      start_id = clinic.id
      end_id = clinic.id

      requests = visit_requests(from, to, cutoff)
      linked = linked_appointments(requests, cutoff)
      linked_ids = linked |> Map.keys() |> MapSet.new()
      day_appointments = appointments(from, to, cutoff)
      attendees = attendees(day_appointments)

      assignments =
        for {_id, at} <- attendees, not is_nil(at.row_id), at.clinician_id == clinician.id, do: at

      mine =
        for a <- day_appointments,
            attendee_id(a, attendees) == clinician.id,
            not MapSet.member?(linked_ids, a.id),
            do: a

      location_ids =
        ([start_id, end_id, clinic.id] ++
           Enum.map(requests, & &1.location_id) ++
           for(a <- mine, a.mode == :mobile, not is_nil(a.location_id), do: a.location_id))
        |> Enum.uniq()
        |> Enum.sort()

      locations = locations(location_ids)

      {commitments, telehealth} =
        mine
        |> Enum.split_with(&(&1.mode != :telehealth))

      unavailable = unavailability(clinician.id, from, to, cutoff)
      shifts = shifts(clinician.id, from, to)

      blocks =
        Enum.map(unavailable, &Map.put(&1, :kind, :unavailable)) ++
          Enum.map(telehealth, &Map.put(&1, :kind, :telehealth))

      commitments = commitments(commitments, clinic.id, blocks)

      visits = visits(requests, linked, clinician, locations)

      involved =
        ([start_id, end_id] ++
           Enum.map(visits, & &1.location_id) ++
           for(c <- commitments, not is_nil(c.location_id), do: c.location_id))
        |> Enum.uniq()
        |> Enum.sort()

      matrix = matrix(matrix_key, cutoff)

      {:ok,
       %{
         day: day,
         effective_at: from,
         horizon_end: to,
         clinician: clinician,
         clinic: clinic,
         start_location_id: start_id,
         end_location_id: end_id,
         matrix_key: matrix_key,
         locations: Map.take(locations, involved),
         visits: Enum.sort_by(visits, & &1.id),
         commitments: Enum.sort_by(commitments, &{&1.starts_at, &1.id}),
         blocks: Enum.sort_by(blocks, &{&1.starts_at, &1.id}),
         shifts: shifts,
         assignments: assignments,
         work_window: work_window(from, shifts, commitments),
         matrix: matrix,
         involved_locations: involved,
         missing_pairs: missing_pairs(matrix, involved)
       }}
    end
  end

  # ── snapshot inputs ────────────────────────────────────────────────────────

  @doc """
  The snapshot inputs for `facts`, sorted by key and role. See `inputs_with_reasons/1`.
  """
  @spec inputs(map()) :: [Input.t()]
  def inputs(facts), do: facts |> inputs_with_reasons() |> elem(0)

  @doc """
  The snapshot inputs and, for each one that is not a `:value`, the reason code a
  person reads in the run's `unresolved_inputs` (`%{input_key => code}`).
  """
  @spec inputs_with_reasons(map()) :: {[Input.t()], %{String.t() => String.t()}}
  def inputs_with_reasons(facts) do
    entries =
      visit_inputs(facts) ++
        commitment_inputs(facts) ++
        block_inputs(facts) ++
        shift_inputs(facts) ++
        assignment_inputs(facts) ++
        location_inputs(facts) ++
        [clinician_input(facts.clinician)] ++
        matrix_inputs(facts)

    inputs = entries |> Enum.map(&elem(&1, 0)) |> Enum.sort_by(&{&1.key, &1.role})

    reasons =
      for {%Input{status: status, key: key}, reason} <- entries,
          status != :value,
          into: %{},
          do: {key, reason}

    {inputs, reasons}
  end

  defp visit_inputs(facts) do
    for v <- facts.visits do
      {input(
         "visit_request:#{v.id}",
         :visit_request,
         @visit_request,
         v.id,
         v.version,
         v.status,
         visit_hash(v)
       ), v.reason}
    end
  end

  defp commitment_inputs(facts) do
    for c <- facts.commitments do
      {input(
         "appointment:#{c.id}",
         :appointment,
         @appointment,
         c.id,
         c.version,
         c.status,
         commitment_hash(c)
       ), c.reason}
    end
  end

  defp block_inputs(facts) do
    for b <- facts.blocks do
      case b.kind do
        :unavailable ->
          {input(
             "availability:#{b.id}",
             :availability,
             @availability,
             b.id,
             b.version,
             :value,
             hash(%{starts_at: b.starts_at, ends_at: b.ends_at})
           ), nil}

        :telehealth ->
          {input(
             "appointment:#{b.id}",
             :appointment,
             @appointment,
             b.id,
             b.version,
             :value,
             hash(%{starts_at: b.starts_at, ends_at: b.ends_at, mode: "telehealth"})
           ), nil}
      end
    end
  end

  defp shift_inputs(facts) do
    for s <- facts.shifts do
      {input(
         "shift:#{s.id}",
         :applied_shift,
         @shift,
         s.id,
         0,
         :value,
         hash(%{starts_at: s.starts_at, ends_at: s.ends_at})
       ), nil}
    end
  end

  defp assignment_inputs(facts) do
    for a <- facts.assignments do
      {input(
         "assignment:#{a.row_id}",
         :applied_assignment,
         @assignment,
         a.row_id,
         0,
         :value,
         hash(%{appointment_id: a.appointment_id, clinician_id: a.clinician_id})
       ), nil}
    end
  end

  defp location_inputs(facts) do
    for {id, l} <- facts.locations do
      {input(
         "service_location:#{id}",
         :service_location,
         @location,
         id,
         0,
         :value,
         hash(%{kind: Atom.to_string(l.kind), access_buffer_minutes: l.access_buffer_minutes})
       ), nil}
    end
  end

  defp clinician_input(c) do
    {input(
       "clinician:#{c.id}",
       :clinician,
       @clinician,
       c.id,
       0,
       :value,
       hash(%{role: Atom.to_string(c.role), mobile_kit: Enum.sort(c.mobile_kit)})
     ), nil}
  end

  # The matrix input: its content hash (the whole artifact), or the reason there is
  # none. Plus one unresolved input per pair the plan needs and the matrix lacks.
  defp matrix_inputs(%{matrix: nil, matrix_key: key}) do
    [
      {%Input{
         key: "travel_matrix:#{key}",
         role: :travel_matrix,
         status: :unresolved,
         source: nil,
         content_hash: nil
       }, "no_published_matrix"}
    ]
  end

  defp matrix_inputs(%{matrix: matrix} = facts) do
    status = if matrix.hash_ok?, do: :value, else: :invalid
    reason = if matrix.hash_ok?, do: nil, else: "matrix_hash_mismatch"

    main =
      {input(
         "travel_matrix:#{matrix.key}",
         :travel_matrix,
         @matrix,
         matrix.id,
         matrix.version,
         status,
         matrix.content_hash
       ), reason}

    pairs =
      for {a, b} <- facts.missing_pairs do
        {%Input{
           key: "travel_pair:#{a}:#{b}",
           role: :travel_matrix,
           status: :unresolved,
           source: %{resource: @matrix, id: matrix.id, version_number: matrix.version},
           content_hash: nil
         }, "travel_pair_missing"}
      end

    [main | pairs]
  end

  defp input(key, role, resource, id, version, status, content_hash) do
    %Input{
      key: key,
      role: role,
      status: status,
      source: %{resource: resource, id: id, version_number: version},
      content_hash: content_hash
    }
  end

  defp visit_hash(v) do
    hash(%{
      window_from: v.window_from,
      window_to: v.window_to,
      booked_minutes: v.booked_minutes,
      service_minutes: v.service_minutes,
      location_id: v.location_id,
      type_name: v.type_name,
      state: Atom.to_string(v.state),
      appointment_id: v.appointment_id,
      previous_starts_at: v.previous_starts_at
    })
  end

  defp commitment_hash(c) do
    hash(%{
      starts_at: c.starts_at,
      ends_at: c.ends_at,
      location_id: c.location_id,
      mode: Atom.to_string(c.mode)
    })
  end

  @doc "Content hash (lowercase hex SHA-256) of any JSON-encodable term."
  @spec hash(term()) :: String.t()
  defdelegate hash(term), to: Reader

  # ── the clinician and the clinic ───────────────────────────────────────────

  defp clinician(clinician_id) do
    case Ash.get(Clinician, clinician_id, actor: Machinery.actor()) do
      {:ok, %{active: true, role: :veterinarian} = c} ->
        {:ok, %{id: c.id, role: c.role, mobile_kit: c.mobile_kit || []}}

      _ ->
        {:error, :clinician_unavailable}
    end
  end

  defp clinic do
    ServiceLocation
    |> Ash.Query.filter(kind == :clinic and active == true)
    |> Ash.Query.sort(name: :asc, id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: Machinery.actor())
    |> case do
      [clinic] -> {:ok, clinic}
      [] -> {:error, :no_clinic_location}
    end
  end

  defp locations([]), do: %{}

  defp locations(ids) do
    ServiceLocation
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(actor: Machinery.actor())
    |> Map.new(&{&1.id, %{kind: &1.kind, access_buffer_minutes: &1.access_buffer_minutes}})
  end

  # ── the day's requests and appointments ────────────────────────────────────

  defp visit_requests(from, to, cutoff) do
    VisitRequest
    |> Ash.Query.as_of(cutoff)
    |> Ash.Query.filter(
      state in [:requested, :scheduled] and earliest_start_at >= ^from and earliest_start_at < ^to
    )
    |> Ash.Query.load(:appointment_type)
    |> Ash.read!(actor: Machinery.actor())
    |> Enum.map(fn r ->
      type = r.appointment_type

      %{
        id: r.id,
        state: r.state,
        window_from: r.earliest_start_at,
        window_to: r.latest_end_at,
        booked_minutes: r.duration_minutes,
        location_id: r.service_location_id,
        patient_id: r.patient_id,
        appointment_type_id: r.appointment_type_id,
        reason_text: r.reason,
        appointment_id: r.appointment_id,
        type_name: type && type.name,
        mobile_capable: (type && type.mobile_capable) || false,
        equipment: (type && type.mobile_equipment) || [],
        version: Reader.version_number(r)
      }
    end)
  end

  defp linked_appointments(requests, cutoff) do
    ids =
      for r <- requests, r.state == :scheduled, not is_nil(r.appointment_id), do: r.appointment_id

    case ids do
      [] ->
        %{}

      ids ->
        Appointment
        |> Ash.Query.as_of(cutoff)
        |> Ash.Query.filter(id in ^ids)
        |> Ash.read!(actor: Machinery.actor())
        |> Map.new(&{&1.id, &1})
    end
  end

  defp appointments(from, to, cutoff) do
    Appointment
    |> Ash.Query.for_read(:in_window, %{from: from, to: to})
    |> Ash.Query.as_of(cutoff)
    |> Ash.Query.filter(status == :scheduled)
    |> Ash.read!(actor: Machinery.actor())
    |> Enum.map(fn a ->
      %{
        id: a.id,
        starts_at: a.scheduled_at,
        ends_at: DateTime.add(a.scheduled_at, a.duration_minutes * 60, :second),
        mode: a.location_mode,
        location_id: a.service_location_id,
        booked_clinician_id: a.clinician_id,
        version: Reader.version_number(a)
      }
    end)
  end

  # Who attends each appointment: the applied roster assignment if there is one,
  # else the booked clinician. `%{appointment_id => %{clinician_id, row_id, appointment_id}}`.
  defp attendees([]), do: %{}

  defp attendees(appointments) do
    ids = Enum.map(appointments, & &1.id)

    assigned =
      Assignment
      |> Ash.Query.filter(state == :scheduled and appointment_id in ^ids)
      |> Ash.read!(actor: Machinery.actor())
      |> Map.new(
        &{&1.appointment_id,
         %{clinician_id: &1.clinician_id, row_id: &1.id, appointment_id: &1.appointment_id}}
      )

    Map.new(appointments, fn a ->
      {a.id,
       Map.get(assigned, a.id, %{
         clinician_id: a.booked_clinician_id,
         row_id: nil,
         appointment_id: a.id
       })}
    end)
  end

  defp attendee_id(appointment, attendees), do: attendees[appointment.id].clinician_id

  defp unavailability(clinician_id, from, to, cutoff) do
    Availability
    |> Ash.Query.as_of(cutoff)
    |> Ash.Query.filter(
      clinician_id == ^clinician_id and available == false and starts_at >= ^from and
        starts_at < ^to
    )
    |> Ash.read!(actor: Machinery.actor())
    |> Enum.map(
      &%{
        id: &1.id,
        starts_at: &1.starts_at,
        ends_at: &1.ends_at,
        version: Reader.version_number(&1)
      }
    )
  end

  defp shifts(clinician_id, from, to) do
    Shift
    |> Ash.Query.filter(
      state == :scheduled and clinician_id == ^clinician_id and starts_at >= ^from and
        starts_at < ^to
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(actor: Machinery.actor())
    |> Enum.map(&%{id: &1.id, starts_at: &1.starts_at, ends_at: &1.ends_at})
  end

  # ── commitments and visits ─────────────────────────────────────────────────

  # A commitment's place: the clinic for an in-clinic visit, its own service location
  # for a mobile one. Flagged `:invalid` when it cannot be planned around.
  defp commitments(appointments, clinic_id, blocks) do
    sorted = Enum.sort_by(appointments, &{&1.starts_at, &1.id})

    sorted
    |> Enum.with_index()
    |> Enum.map(fn {a, index} ->
      earlier = Enum.take(sorted, index)

      location =
        case a.mode do
          :in_clinic -> clinic_id
          :mobile -> a.location_id
        end

      {status, reason} =
        cond do
          is_nil(location) -> {:invalid, "no_service_location"}
          crosses_midnight?(a) -> {:invalid, "crosses_midnight"}
          Enum.any?(earlier ++ blocks, &overlap?(a, &1)) -> {:invalid, "commitment_overlap"}
          true -> {:value, nil}
        end

      Map.merge(a, %{location_id: location, status: status, reason: reason})
    end)
  end

  defp visits(requests, linked, clinician, locations) do
    for r <- requests, visit = visit(r, linked[r.appointment_id], clinician, locations), visit do
      visit
    end
  end

  # A scheduled request whose booked appointment is another veterinarian's is that
  # veterinarian's route, not this one: it is skipped (`nil`).
  defp visit(%{state: :scheduled} = r, appointment, clinician, locations) do
    cond do
      is_nil(appointment) or appointment.status != :scheduled ->
        build_visit(r, nil, clinician, locations, "linked_appointment_not_scheduled")

      appointment.clinician_id != clinician.id ->
        nil

      true ->
        build_visit(r, appointment.scheduled_at, clinician, locations, nil)
    end
  end

  defp visit(r, _appointment, clinician, locations),
    do: build_visit(r, nil, clinician, locations, nil)

  defp build_visit(r, previous_starts_at, clinician, locations, forced_reason) do
    buffer = locations |> Map.fetch!(r.location_id) |> Map.fetch!(:access_buffer_minutes)

    reason =
      cond do
        forced_reason -> forced_reason
        not r.mobile_capable -> "type_not_mobile_capable"
        not Enum.all?(r.equipment, &(&1 in clinician.mobile_kit)) -> "equipment_not_carried"
        true -> nil
      end

    Map.merge(r, %{
      previous_starts_at: previous_starts_at,
      buffer_minutes: buffer,
      service_minutes: r.booked_minutes + buffer,
      status: if(reason, do: :invalid, else: :value),
      reason: reason
    })
  end

  defp crosses_midnight?(%{starts_at: starts_at, ends_at: ends_at}),
    do: DateTime.to_date(starts_at) != DateTime.to_date(DateTime.add(ends_at, -1, :second))

  defp overlap?(a, b),
    do:
      DateTime.compare(a.starts_at, b.ends_at) == :lt and
        DateTime.compare(b.starts_at, a.ends_at) == :lt

  # ── the working window ─────────────────────────────────────────────────────

  # The applied shift (earliest start to latest end) or the default hours, widened
  # to hold every commitment: pinned work is never outside the day the plan models.
  defp work_window(day_start, shifts, commitments) do
    {base_from, base_to, source} =
      case shifts do
        [] ->
          {at(day_start, @default_work_from_minute), at(day_start, @default_work_to_minute),
           :default}

        shifts ->
          {shifts |> Enum.map(& &1.starts_at) |> Enum.min(DateTime),
           shifts |> Enum.map(& &1.ends_at) |> Enum.max(DateTime), :shift}
      end

    from = Enum.reduce(commitments, base_from, &earliest(&1.starts_at, &2))
    to = Enum.reduce(commitments, base_to, &latest(&1.ends_at, &2))
    %{from: from, to: to, source: source}
  end

  defp at(day_start, minute), do: DateTime.add(day_start, minute * 60, :second)
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)
  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  # ── the matrix ─────────────────────────────────────────────────────────────

  defp matrix(key, cutoff) do
    TravelMatrix
    |> Ash.Query.filter(key == ^key and published_at <= ^cutoff)
    |> Ash.Query.sort(version: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: Machinery.actor())
    |> case do
      [row] ->
        %{
          id: row.id,
          key: row.key,
          version: row.version,
          content_hash: row.content_hash,
          hash_ok?: TravelMatrix.content_hash(Map.from_struct(row)) == row.content_hash,
          pairs:
            Map.new(row.entries, fn e ->
              {{e["origin_id"], e["destination_id"]},
               %{reachable: e["reachable"], minutes: e["duration_minutes"]}}
            end)
        }

      [] ->
        nil
    end
  end

  # Every ordered pair of distinct places the plan involves must be in the matrix.
  defp missing_pairs(nil, _involved), do: []

  defp missing_pairs(%{pairs: pairs}, involved) do
    for a <- involved, b <- involved, a != b, not Map.has_key?(pairs, {a, b}), do: {a, b}
  end
end
