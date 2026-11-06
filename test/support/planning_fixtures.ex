defmodule ClinicDemo.PlanningFixtures do
  @moduledoc """
  Synthetic clinic fixtures for the weekly roster tests: a small team (a head vet,
  a second vet, a nurse who is also the clinic manager, a technician), the shift
  patterns the staffing policy names, and appointments booked in a week ahead.

  Nothing here is real: names, licences and e-mails are made up, and no fixture
  describes a real clinic or patient.
  """

  alias ClinicDemo.Planning.WeeklyRoster
  alias ClinicDemo.Scheduling

  @staff %{id: "00000000-0000-0000-0000-0000000000aa", role: :veterinarian}

  @doc "A bare staff actor (the clinic has no authentication; any map with an id will do)."
  def staff, do: @staff

  @doc "The Monday of next week, so every booking is in the future."
  def next_monday do
    Date.utc_today() |> Date.beginning_of_week() |> Date.add(7)
  end

  @doc """
  Hires the team and defines the shift patterns. Returns a map with the clinicians
  (`:head_vet`, `:vet`, `:manager`, `:tech`) and the patterns by `{name, role}`.
  """
  def team! do
    head_vet = hire!("Dr. Vera Vale", :veterinarian, leadership: :head_vet)
    vet = hire!("Dr. Vik Vance", :veterinarian)
    manager = hire!("Nora Nash", :nurse, leadership: :clinic_manager)
    tech = hire!("Tess Tull", :technician)

    templates =
      for role <- [:veterinarian, :technician, :nurse],
          {name, from, to, days} <- [
            {"early", 8 * 60, 16 * 60, [1, 2, 3, 4, 5]},
            {"late", 10 * 60, 18 * 60, [1, 2, 3, 4, 5]},
            {"weekend", 9 * 60, 13 * 60, [6]}
          ],
          into: %{} do
        {{name, role},
         Scheduling.define_shift_template!(
           %{
             name: name,
             role: role,
             start_offset_minutes: from,
             end_offset_minutes: to,
             allowed_days: days
           },
           actor: @staff
         )}
      end

    %{head_vet: head_vet, vet: vet, manager: manager, tech: tech, templates: templates}
  end

  @doc "Books an appointment `day` (1 = Monday) of `week_start`'s week at `hhmm` (e.g. `{10, 0}`)."
  def book!(week_start, day, {hour, minute}, clinician, opts \\ []) do
    patient =
      Scheduling.register_patient!(
        %{
          name: "Patient #{System.unique_integer([:positive])}",
          species: :dog,
          owner_email: unique_email()
        },
        actor: @staff
      )

    scheduled_at =
      week_start
      |> Date.add(day - 1)
      |> DateTime.new!(Time.new!(hour, minute, 0), "Etc/UTC")

    params =
      %{
        patient_id: patient.id,
        clinician_id: clinician.id,
        scheduled_at: scheduled_at,
        duration_minutes: Keyword.get(opts, :duration, 30),
        reason: Keyword.get(opts, :reason, "Synthetic checkup")
      }
      |> maybe_put(:appointment_type_id, opts[:type] && opts[:type].id)

    Scheduling.book_appointment!(params, actor: @staff)
  end

  @doc "A catalogue entry (the staffing policy keys on its name)."
  def type!(name) do
    case Enum.find(Scheduling.list_appointment_types!(), &(&1.name == name)) do
      nil ->
        Ash.create!(
          ClinicDemo.Scheduling.AppointmentType,
          %{name: name, base_price: "50", default_duration_minutes: 30},
          authorize?: false
        )

      type ->
        type
    end
  end

  @doc "Declares a clinician unavailable for `[from, to)` on `day` of the week."
  def remove_availability!(
        week_start,
        day,
        clinician,
        {from_h, from_m},
        {to_h, to_m},
        reason \\ "leave"
      ) do
    date = Date.add(week_start, day - 1)

    Scheduling.declare_availability!(
      %{
        clinician_id: clinician.id,
        starts_at: DateTime.new!(date, Time.new!(from_h, from_m, 0), "Etc/UTC"),
        ends_at: DateTime.new!(date, Time.new!(to_h, to_m, 0), "Etc/UTC"),
        available: false,
        reason: reason
      },
      actor: @staff
    )
  end

  @doc """
  A scripted backend answer for the Fake backend, built from the decoded problem
  payload: `shifts` is `[{clinician_id, day, template_name}]` and `covers` is
  `[{appointment_id, clinician_id}]`. Returns the `"pat"`/`"asg"` arrays in the
  model's output shape.
  """
  def fake_answer(payload, shifts, covers) do
    ids = payload["ids"]
    templates = payload["problem"]["templates"]
    clinicians = ids["clinicians"]

    pat =
      for c <- 0..length(clinicians), day <- 1..7 do
        with true <- c > 0,
             clinician_id = Enum.at(clinicians, c - 1),
             {^clinician_id, ^day, name} <-
               Enum.find(shifts, &match?({^clinician_id, ^day, _}, &1)),
             role =
               Enum.find(payload["problem"]["clinicians"], &(&1["id"] == clinician_id))["role"],
             %{"id" => template_id} <-
               Enum.find(templates, &(&1["name"] == name and &1["role"] == role)) do
          Enum.find_index(ids["templates"], &(&1 == template_id)) + 1
        else
          _ -> 0
        end
      end

    asg =
      for appointment_id <- ids["appointments"] do
        case List.keyfind(covers, appointment_id, 0) do
          {_, clinician_id} -> Enum.find_index(clinicians, &(&1 == clinician_id)) + 1
          nil -> 0
        end
      end

    %{"pat" => pat, "asg" => asg, "obj" => 0}
  end

  @doc """
  Plans `week_start` through the Fake backend with a scripted answer.

  `shifts_and_covers` is `fn payload -> {shifts, covers} end` (see `fake_answer/3`).
  Option `:fake` is a map merged into the scripted backend's data (`fake_outcome`,
  `fake_objective`, ...); every other option goes to `WeeklyRoster.plan/1`.
  """
  def plan_fake(week_start, actor, shifts_and_covers, opts \\ []) do
    {fake, opts} = Keyword.pop(opts, :fake, %{})

    WeeklyRoster.plan(
      [
        week_start: week_start,
        actor: actor,
        backend: AshPlanning.Backend.Fake,
        backend_data: fn payload ->
          {shifts, covers} = shifts_and_covers.(payload)
          Map.merge(%{fake_candidates: [fake_answer(payload, shifts, covers)]}, fake)
        end
      ] ++ opts
    )
  end

  defp hire!(name, role, opts \\ []) do
    params =
      %{full_name: name, role: role, leadership: opts[:leadership]}
      |> maybe_put(
        :license_number,
        if(role == :veterinarian, do: "ON-#{:rand.uniform(899_999) + 100_000}")
      )

    Scheduling.hire_clinician!(params, actor: @staff)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp unique_email, do: "owner-#{System.unique_integer([:positive])}@example.com"
end
