defmodule ClinicDemo.Planning.RosterGantt do
  @moduledoc """
  The `/roster` surface's live diagram: the week the clinic is about to work
  — next week's Monday through Sunday — as a mermaid gantt.

  The window is the planning week, not the wall-clock week: `plan_week` plans
  next week by default (the flagship fixtures' convention — a plan is asked
  for a week not half spent), and approving its candidate places next week's
  shifts. A gantt of the current week could therefore never show what a plan
  proposes; this one redraws the moment the apply lands.

  One bar per placed shift, grouped into a section per clinician, plus a final
  "Uncovered appointments" section: appointments booked into the week that no
  scheduled assignment covers — the coverage band, honestly derived rather
  than asserted. `dateFormat X` puts the axis on unix seconds, so half-hour
  appointments and eight-hour shifts share one native scale. Bars are drawn
  across the whole week — no `excludes weekends`, because a clinic roster has
  Saturday shifts and an axis that hides them would lie. The engine renders
  with `securityLevel: "strict"`, so the diagram is read-only by
  construction: no click handlers exist to attach.

  This is the industry-standard roster shape — per-person timeline rows plus a
  coverage surfacing (Kronos/UKG, Odoo Planning, Timefold) — reached through
  the kit's existing live-diagram part: no Atlas addition, no new kit part.
  The recorded gap is interactivity: no drag-to-adjust, on purpose — the
  solver proposes, the person commits through four-eyes sign-off on the
  Worklist.

  A pure `gantt/3` builds the mermaid text from plain bar maps; the callback
  only reads and shapes, so the diagram text is testable without a database.

  Cancelled shifts are excluded, not drawn: a cancelled row is a roster the
  clinic was told and then replaced — the Shifts list below the gantt shows
  the full history with its state column.
  """

  @behaviour AshA2ui.Diagram.Source

  alias ClinicDemo.Scheduling

  @impl true
  def diagram(%{actor: actor}) do
    monday = Date.utc_today() |> Date.beginning_of_week() |> Date.add(7)
    week_end = Date.add(monday, 7)
    from = DateTime.new!(monday, ~T[00:00:00], "Etc/UTC")
    to = DateTime.new!(week_end, ~T[00:00:00], "Etc/UTC")

    with {:ok, shifts} <-
           Scheduling.list_shifts(
             actor: actor,
             query: [
               filter: [state: :scheduled, starts_at: [greater_than_or_equal: from, less_than: to]]
             ],
             load: [:clinician]
           ),
         {:ok, appointments} <-
           Scheduling.appointments_in_window(from, to,
             actor: actor,
             load: [:patient, :appointment_type]
           ),
         {:ok, assignments} <- Scheduling.list_assignments(actor: actor) do
      covered = MapSet.new(assignments, & &1.appointment_id)

      uncovered =
        appointments
        |> Enum.reject(&(&1.status == :cancelled))
        |> Enum.reject(&MapSet.member?(covered, &1.id))

      {:ok,
       %{
         source: gantt(monday, Enum.map(shifts, &shift_bar/1), Enum.map(uncovered, &appointment_bar/1)),
         markers: []
       }}
    end
  end

  @doc """
  The mermaid gantt for one week: `shift_bars` under a section per clinician
  (bars carry `:clinician`), `uncovered_bars` under the coverage section.
  Pure — plain maps in, mermaid text out.
  """
  @spec gantt(Date.t(), [bar()], [bar()]) :: String.t()
  def gantt(monday, shift_bars, uncovered_bars) do
    header = [
      "gantt",
      "  title Clinic roster — week of Monday #{Date.to_iso8601(monday)}",
      "  dateFormat X",
      "  axisFormat %a %H:%M"
    ]

    per_clinician =
      shift_bars
      |> Enum.group_by(& &1.clinician)
      |> Enum.sort_by(fn {_name, bars} -> Enum.map(bars, & &1.start) end)
      |> Enum.flat_map(fn {clinician, bars} ->
        ["  section #{escape(clinician)}" | Enum.map(bars, &shift_line/1)]
      end)

    coverage =
      if uncovered_bars == [] do
        []
      else
        ["  section Uncovered appointments" | Enum.map(uncovered_bars, &appointment_line/1)]
      end

    Enum.join(header ++ per_clinician ++ coverage, "\n")
  end

  @type bar :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:start) => DateTime.t(),
          required(:seconds) => pos_integer()
        }

  # A placed shift: `  veterinarian shift :shift-<id>, <unix-start>, <seconds>`
  defp shift_line(%{id: id, label: label, start: start, seconds: seconds}),
    do: "  #{escape(label)} :shift-#{id}, #{DateTime.to_unix(start)}, #{seconds}"

  # An uncovered appointment: `  Bella Wellness exam :crit, appt-<id>, <unix>, <seconds>`
  defp appointment_line(%{id: id, label: label, start: start, seconds: seconds}),
    do: "  #{escape(label)} :crit, appt-#{id}, #{DateTime.to_unix(start)}, #{seconds}"

  # Mermaid gantt splits a task line on ":"; a colon in a clinician or
  # appointment label would cut the line short. Replacing it with a space can
  # double a space ("Semi: Colon" → "Semi  Colon"), so collapse runs of
  # whitespace after. Nothing else in this demo's inputs needs escaping in the
  # task-name position.
  defp escape(text) do
    text
    |> String.replace(":", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp shift_bar(shift) do
    %{
      id: shift.id,
      clinician: (shift.clinician && shift.clinician.full_name) || "Clinician",
      label: "#{shift.role} shift",
      start: shift.starts_at,
      seconds: DateTime.diff(shift.ends_at, shift.starts_at)
    }
  end

  defp appointment_bar(appointment) do
    # "<Patient/type>": the name a person knows the booking by — the patient's,
    # else the visit type's, else the reason, else "Appointment".
    label =
      Enum.find(
        [
          patient_name(appointment),
          type_name(appointment),
          appointment.reason,
          "Appointment"
        ],
        &(is_binary(&1) and &1 != "")
      )

    %{
      id: appointment.id,
      label: label,
      start: appointment.scheduled_at,
      seconds: appointment.duration_minutes * 60
    }
  end

  defp patient_name(%{patient: %{name: name}}) when is_binary(name), do: name
  defp patient_name(_), do: nil

  defp type_name(%{appointment_type: %{name: name}}) when is_binary(name), do: name
  defp type_name(_), do: nil
end
