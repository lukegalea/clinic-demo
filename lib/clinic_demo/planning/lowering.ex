defmodule ClinicDemo.Planning.Lowering do
  @moduledoc """
  Facts in, `weekly_roster.mzn` data out, and the model's answer back to
  domain-level assignments.

  This is the **model-lowering** half of the roster and it is the only module that
  knows the model's slot grid, its role codes and its index conventions:

    * time is a grid of 15-minute slots, absolute within the week (Monday 00:00
      UTC is slot 0), half-open `[from, to)`;
    * an appointment occupies the slots from `floor(start)` to `ceil(end)`, so
      rounding never frees a slot an appointment uses;
    * clinicians, templates and appointments are indexed from 1 in the order of
      the `"ids"` arrays recorded in the payload, so a model answer can always be
      read back without the facts.

  `ClinicDemo.Planning.RosterValidator` shares none of this: it reads
  `"problem"` (the same facts at domain level, in minutes and instants) and the
  decoded assignments, so a lowering bug and a validator bug must coincide to slip
  a bad roster through.
  """

  @slot_minutes 15
  @slots_per_day div(24 * 60, @slot_minutes)
  @days 7

  @role_codes %{veterinarian: 1, technician: 2, nurse: 3}

  # The objective weights are data to the model, so a reviewed change here is not a
  # model edit. An applied assignment is worth far more than anything else (it was
  # communicated), then a covered appointment, then continuity, then tidiness.
  @weights %{
    "w_uncovered" => 1000,
    "w_idle" => 1,
    "w_shift_change" => 100,
    "w_assign_change" => 100_000,
    "w_continuity" => 20
  }

  @urgency_weight %{emergency: 4, urgent: 3, soon: 2, routine: 1}

  @doc "Minutes per slot."
  @spec slot_minutes() :: pos_integer()
  def slot_minutes, do: @slot_minutes

  @doc """
  Lowers annotated facts to the model's data.

  Returns `{:ok, %{"data" => data, "ids" => ids}}`. `"ids"` maps each model index
  back to a record id: `"clinicians"`, `"templates"`, `"appointments"`.
  """
  @spec lower(map()) :: {:ok, map()} | {:error, term()}
  def lower(%{} = facts) do
    with {:ok, templates} <- lower_templates(facts) do
      clinicians = facts.clinicians
      appointments = facts.appointments
      clinician_index = index(clinicians)
      template_index = index(facts.templates)

      unavailable =
        for a <- facts.availabilities,
            not a.available,
            c = clinician_index[a.clinician_id],
            not is_nil(c),
            do:
              {c, floor_slot(a.starts_at, facts.effective_at),
               ceil_slot(a.ends_at, facts.effective_at)}

      data =
        Map.merge(@weights, %{
          "spd" => @slots_per_day,
          "n_clin" => length(clinicians),
          "clin_role" => pad(Enum.map(clinicians, &Map.fetch!(@role_codes, &1.role)), 0),
          "n_tmpl" => length(facts.templates),
          "t_role" => pad(templates.roles, 0),
          "t_from" => pad(templates.from, 0),
          "t_to" => pad(templates.to, 0),
          "t_day_ok" => pad(templates.day_ok, false),
          "n_unavail" => length(unavailable),
          "u_clin" => pad(Enum.map(unavailable, &elem(&1, 0)), 0),
          "u_from" => pad(Enum.map(unavailable, &elem(&1, 1)), 0),
          "u_to" => pad(Enum.map(unavailable, &elem(&1, 2)), 0),
          "n_appt" => length(appointments),
          "a_from" =>
            pad(Enum.map(appointments, &floor_slot(&1.starts_at, facts.effective_at)), 0),
          "a_to" =>
            pad(Enum.map(appointments, &ceil_slot(&1.planned_ends_at, facts.effective_at)), 0),
          "a_role" => pad(Enum.map(appointments, &Map.fetch!(@role_codes, &1.required_role)), 0),
          "a_weight" => pad(Enum.map(appointments, &Map.get(@urgency_weight, &1.urgency, 1)), 0),
          "a_booked" =>
            pad(Enum.map(appointments, &Map.get(clinician_index, &1.booked_clinician_id, 0)), 0),
          "a_prev" => pad(a_prev(appointments, facts.assignments, clinician_index), 0),
          "prev_pat" => pad(prev_pat(facts, clinician_index, template_index), -1),
          "reserve_slots" =>
            for(
              day <- 1..@days,
              do: ceil_div(Map.fetch!(facts.policy.week, day).reserve_minutes, @slot_minutes)
            )
        })

      {:ok,
       %{
         "data" => data,
         "ids" => %{
           "clinicians" => Enum.map(clinicians, & &1.id),
           "templates" => Enum.map(facts.templates, & &1.id),
           "appointments" => Enum.map(appointments, & &1.id)
         }
       }}
    end
  end

  @doc """
  Reads one model answer (`"pat"`, `"asg"`) back to domain-level assignments:

      %{
        "shifts" => [%{"clinician_id", "role", "starts_at", "ends_at", "shift_template_id"}],
        "assignments" => [%{"appointment_id", "clinician_id", "role"}],
        "uncovered" => [appointment_id]
      }

  Instants are ISO-8601 strings; nothing here is a number the validator has to
  trust.
  """
  @spec decode(map(), map()) :: {:ok, map()} | {:error, term()}
  def decode(%{"ids" => ids, "data" => data, "problem" => problem}, %{} = answer) do
    with {:ok, effective_at} <- effective_at(problem),
         pat when is_list(pat) <- answer["pat"],
         asg when is_list(asg) <- answer["asg"],
         true <- length(asg) == length(ids["appointments"]),
         true <- length(pat) == (length(ids["clinicians"]) + 1) * @days do
      roles =
        Map.new(Enum.zip(ids["clinicians"], data["clin_role"]), fn {id, code} ->
          {id, role_of(code)}
        end)

      shifts =
        for {clinician_id, c} <- Enum.with_index(ids["clinicians"], 1),
            day <- 1..@days,
            p = Enum.at(pat, c * @days + day - 1),
            p != 0 do
          from_minute = Enum.at(data["t_from"], p - 1) * @slot_minutes
          to_minute = Enum.at(data["t_to"], p - 1) * @slot_minutes
          day_start = DateTime.add(effective_at, (day - 1) * 86_400, :second)

          %{
            "clinician_id" => clinician_id,
            "role" => Atom.to_string(Map.fetch!(roles, clinician_id)),
            "starts_at" =>
              day_start |> DateTime.add(from_minute * 60, :second) |> DateTime.to_iso8601(),
            "ends_at" =>
              day_start |> DateTime.add(to_minute * 60, :second) |> DateTime.to_iso8601(),
            "shift_template_id" => Enum.at(ids["templates"], p - 1)
          }
        end

      covered =
        for {appointment_id, c} <- Enum.zip(ids["appointments"], asg), c != 0 do
          clinician_id = Enum.at(ids["clinicians"], c - 1)

          %{
            "appointment_id" => appointment_id,
            "clinician_id" => clinician_id,
            "role" => Atom.to_string(Map.fetch!(roles, clinician_id))
          }
        end

      uncovered =
        for {appointment_id, 0} <- Enum.zip(ids["appointments"], asg), do: appointment_id

      {:ok, %{"shifts" => shifts, "assignments" => covered, "uncovered" => uncovered}}
    else
      _ -> {:error, :answer_unreadable}
    end
  end

  def decode(_payload, _answer), do: {:error, :answer_unreadable}

  # ── templates ──────────────────────────────────────────────────────────────

  # A template runs on a day only if the template allows it AND the staffing
  # policy's allowed patterns for that weekday name it.
  defp lower_templates(%{templates: templates, policy: policy}) do
    aligned? =
      Enum.all?(
        templates,
        &(rem(&1.from_minute, @slot_minutes) == 0 and rem(&1.to_minute, @slot_minutes) == 0)
      )

    if aligned? do
      {:ok,
       %{
         roles: Enum.map(templates, &Map.fetch!(@role_codes, &1.role)),
         from: Enum.map(templates, &div(&1.from_minute, @slot_minutes)),
         to: Enum.map(templates, &div(&1.to_minute, @slot_minutes)),
         day_ok:
           for t <- templates, day <- 1..@days do
             day in t.days and t.name in Map.fetch!(policy.week, day).patterns
           end
       }}
    else
      {:error, :template_not_slot_aligned}
    end
  end

  # ── the previously applied plan ────────────────────────────────────────────

  defp a_prev(appointments, assignments, clinician_index) do
    by_appointment = Map.new(assignments, &{&1.appointment_id, &1.clinician_id})

    Enum.map(appointments, fn a ->
      Map.get(clinician_index, Map.get(by_appointment, a.id), 0)
    end)
  end

  # -1 everywhere when nothing was applied (a first plan has nothing to preserve);
  # otherwise 0 (not working) where the applied plan had no shift, and the template
  # index where it had one.
  defp prev_pat(%{shifts: []}, clinician_index, _template_index) do
    List.duplicate(-1, map_size(clinician_index) * @days)
  end

  defp prev_pat(
         %{shifts: shifts, effective_at: effective_at, templates: templates},
         clinician_index,
         template_index
       ) do
    placed =
      for s <- shifts, c = clinician_index[s.clinician_id], not is_nil(c), into: %{} do
        day = div(DateTime.diff(s.starts_at, effective_at, :second), 86_400) + 1
        {{c, day}, template_for(s, templates, template_index)}
      end

    for c <- 1..map_size(clinician_index)//1, day <- 1..@days do
      Map.get(placed, {c, day}, 0)
    end
  end

  defp template_for(%{shift_template_id: id} = shift, templates, template_index) do
    case Map.get(template_index, id) do
      nil -> by_offsets(shift, templates)
      index -> index
    end
  end

  defp by_offsets(shift, templates) do
    from = minute_of_day(shift.starts_at)
    to = from + div(DateTime.diff(shift.ends_at, shift.starts_at, :second), 60)

    case Enum.find_index(
           templates,
           &(&1.role == shift.role and &1.from_minute == from and &1.to_minute == to)
         ) do
      nil -> 0
      index -> index + 1
    end
  end

  # Every array that can be empty carries one trailing pad element: Solverl renders
  # an empty list as `array0d([])`, which MiniZinc rejects for a one-dimensional
  # array. The model declares these `array[int]` and reads only the first `n_*`
  # entries (see `weekly_roster.mzn`).
  defp pad(list, fill), do: list ++ [fill]

  # ── small helpers ──────────────────────────────────────────────────────────

  defp index(records), do: records |> Enum.with_index(1) |> Map.new(fn {r, i} -> {r.id, i} end)

  defp minute_of_day(%DateTime{} = dt), do: dt.hour * 60 + dt.minute

  defp floor_slot(%DateTime{} = at, %DateTime{} = week_start),
    do: div(DateTime.diff(at, week_start, :second), @slot_minutes * 60)

  defp ceil_slot(%DateTime{} = at, %DateTime{} = week_start),
    do: ceil_div(DateTime.diff(at, week_start, :second), @slot_minutes * 60)

  defp ceil_div(a, b), do: div(a + b - 1, b)

  defp role_of(1), do: :veterinarian
  defp role_of(2), do: :technician
  defp role_of(3), do: :nurse

  defp effective_at(%{"week_start" => week_start}) do
    with {:ok, date} <- Date.from_iso8601(week_start),
         do: {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
  end
end
