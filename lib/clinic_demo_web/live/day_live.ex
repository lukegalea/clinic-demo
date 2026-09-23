defmodule ClinicDemoWeb.DayLive do
  @moduledoc """
  The Day view — the clinic's day at a glance, built on the NB component
  layer (nb-calendar, nb-item, nb-sheet) rather than an A2UI surface.

  Why host components instead of a surface: this view is chrome *around*
  the data, not a data surface — a month grid for picking, a day's list
  with statuses, one read-only detail panel. The NB layer exists exactly
  for that (ash_a2ui's Lane D), and it speaks the app's palette through
  the `--a2ui-*` bridge with no overrides.

  Contract with the components (their events are `composed`, so phx hooks
  on the host elements see them):

    - `nb-calendar` emits `nb-select {date}` / `nb-month-change {month}`;
      the `DayCalendar` hook pushes them as `select_day` / `select_month`.
    - appointment rows are `nb-item`s with `phx-click` → `open_detail`;
      the status attr carries the lane vocabulary the whole app shares.
    - the detail panel is an `nb-sheet` — it closes itself client-side and
      emits `nb-close`; the `DaySheet` hook pushes `close_detail` so the
      server assign follows the DOM (never leads — zero jank).

  Presence rides the shared `SurfaceChrome` wiring on this route's own
  topic, so the nav's who-else-is-here chip works here like on every
  surface. Times and day buckets are UTC — the app's convention (the agent
  clock, the surfaces' stamps); the two agree by construction.

  Read-only by design: appointment clicks open this view's detail sheet
  with a link to the board; no edit form lives here.
  """

  use ClinicDemoWeb, :live_view

  require Ash.Query

  alias ClinicDemo.Scheduling.Appointment
  alias ClinicDemoWeb.A2ui.SurfaceChrome

  @surface_id "clinic_day"

  @impl true
  def mount(_params, _session, socket) do
    today = Date.utc_today()

    socket =
      socket
      |> assign(:today, today)
      |> assign(:month, month_iso(today))
      |> assign(:selected_day, today)
      |> assign(:detail_id, nil)
      |> load_appointments()
      |> recompute()

    {:ok, SurfaceChrome.mount_presence(socket, @surface_id)}
  end

  @impl true
  def handle_event("select_day", %{"date" => date}, socket) do
    case Date.from_iso8601(date) do
      {:ok, day} ->
        {:noreply,
         socket
         |> assign(selected_day: day, detail_id: nil)
         |> roll_month(day)
         |> recompute()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("select_month", %{"month" => month}, socket) do
    case Date.from_iso8601(month <> "-01") do
      {:ok, first} -> {:noreply, assign(socket, :month, month_iso(first))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("open_detail", %{"id" => id}, socket) do
    {:noreply, assign(socket, :detail_id, id) |> recompute()}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, :detail_id, nil) |> recompute()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-6">
      <header>
        <h1 class="text-2xl font-display">Day</h1>
        <p class="text-foreground/70">
          The clinic one day at a time — pick a day, see who's in, open a visit's details. All times UTC.
        </p>
      </header>

      <div class="flex flex-col gap-8 lg:flex-row lg:items-start">
        <section aria-label="Appointment calendar">
          <%!-- The month grid. `items` carries which days have
               appointments (the tilted sticker dots); today wears its
               ring; the selected day lifts on the accent shadow. --%>
          <nb-calendar
            id="day-calendar"
            phx-hook="DayCalendar"
            month={@month}
            selected={Date.to_iso8601(@selected_day)}
            today={Date.to_iso8601(@today)}
            items={@item_dates}
          />
        </section>

        <section class="min-w-0 flex-1" aria-label="Day detail">
          <h2 class="mb-3 text-lg font-heading">
            <span
              class="mr-2 inline-block size-3.5 -rotate-6 rounded-base border-2 border-border bg-main"
              aria-hidden="true"
            />
            {day_heading(@selected_day)}
            <span class="ml-2 text-sm font-base text-foreground/60">
              {length(@upcoming) + length(@earlier)} appointments
            </span>
          </h2>

          <div class="flex flex-col gap-2">
            <.appointment_item :for={appointment <- @upcoming} appointment={appointment} />
          </div>

          <%!-- The day's earlier half: present but folded — a day's tail
               is reference, not the working set. Native <details>: free
               keyboard access, no JS. --%>
          <details
            :if={@earlier != []}
            class="mt-4 rounded-base border-2 border-border bg-secondary-background px-4 py-3 shadow-shadow"
          >
            <summary class="cursor-pointer font-heading">
              Earlier today ({length(@earlier)})
            </summary>
            <div class="mt-3 flex flex-col gap-2">
              <.appointment_item :for={appointment <- @earlier} appointment={appointment} />
            </div>
          </details>

          <.empty_state
            :if={@upcoming == [] and @earlier == []}
            icon="hero-calendar-days"
            class="mt-2"
          >
            Nothing on the books for this day — the calendar's dots mark the days that have visits.
          </.empty_state>
        </section>
      </div>
    </div>

    <%!-- The read-only detail sheet. nb-sheet closes itself on
         Escape/backdrop (client-side, instant) and emits nb-close; the
         DaySheet hook tells this LiveView to drop the assign so the next
         patch agrees with the DOM. --%>
    <nb-sheet
      :if={@detail}
      id="day-detail-sheet"
      phx-hook="DaySheet"
      label={"#{@detail.patient_label} — #{@detail.reason}"}
      open=""
    >
      <div class="flex flex-col gap-3 font-base">
        <div class="flex flex-wrap gap-2">
          <span class={"rounded-base border-2 border-border px-2.5 py-0.5 text-xs font-base #{status_fill(@detail)}"}>
            {status_label(@detail)}
          </span>
          <span class="rounded-base border-2 border-border bg-secondary-background px-2.5 py-0.5 text-xs font-base">
            {time_range(@detail)}
          </span>
        </div>

        <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 text-sm">
          <dt class="font-heading">Patient</dt>
          <dd>{@detail.patient_label}</dd>
          <dt class="font-heading">Clinician</dt>
          <dd>{@detail.clinician_label || "—"}</dd>
          <dt class="font-heading">Reason</dt>
          <dd>{@detail.reason}</dd>
          <dt class="font-heading">Triage</dt>
          <dd>{@detail.triage_urgency || "not triaged"}</dd>
          <dt class="font-heading">Severity</dt>
          <dd>{@detail.severity || "—"}</dd>
        </dl>

        <p class="text-sm text-foreground/60">
          Read-only — moves happen on the board, where the process state machine guards them.
        </p>

        <.link
          navigate={~p"/"}
          class="inline-flex h-10 items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 border-border bg-main px-4 py-2 text-sm font-base text-main-foreground shadow-shadow ring-offset-white transition-all focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-black focus-visible:ring-offset-2 hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press"
        >
          View on the board
        </.link>
      </div>
    </nb-sheet>
    """
  end

  # --- components -------------------------------------------------------------

  attr :appointment, Appointment, required: true

  defp appointment_item(assigns) do
    ~H"""
    <nb-item
      phx-click="open_detail"
      phx-value-id={@appointment.id}
      status={status_vocab(@appointment)}
      label={"#{@appointment.patient_label} — #{@appointment.reason}"}
      meta={
        time_range(@appointment) <>
          if(clinician = @appointment.clinician_label, do: " · " <> clinician, else: "")
      }
      selectable
    />
    """
  end

  # --- data -------------------------------------------------------------------

  # Demo scale: the whole book once per mount (the board loads the same
  # world). Live navigation from intake re-mounts this view, so a fresh
  # booking is on the calendar the moment the visitor lands here.
  defp load_appointments(socket) do
    appointments =
      Appointment
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(status != :cancelled)
      |> Ash.Query.load(:patient_label)
      |> Ash.Query.load(:clinician_label)
      |> Ash.Query.sort(scheduled_at: :asc)
      |> Ash.read!(authorize?: false)

    assign(socket, :appointments, appointments)
  end

  # Derives everything the template reads from the base assigns, so every
  # event handler ends in one recompute/1.
  defp recompute(socket) do
    day_iso = Date.to_iso8601(socket.assigns.selected_day)
    now = DateTime.utc_now()

    {upcoming, earlier} =
      socket.assigns.appointments
      |> Enum.filter(&(day_iso(&1.scheduled_at) == day_iso))
      |> Enum.split_with(&(DateTime.compare(&1.scheduled_at, now) != :lt))

    item_dates =
      socket.assigns.appointments
      |> Enum.filter(&(month_of(day_iso(&1.scheduled_at)) == socket.assigns.month))
      |> Enum.map(&day_iso(&1.scheduled_at))
      |> Enum.uniq()

    socket
    |> assign(:upcoming, upcoming)
    |> assign(:earlier, earlier)
    |> assign(:item_dates, Enum.join(item_dates, ","))
    |> assign(:detail, Enum.find(upcoming ++ earlier, &(&1.id == socket.assigns.detail_id)))
  end

  # Page the calendar along when a picked day lives outside the rendered
  # month (keyboard month crossings already emit nb-month-change, but a
  # programmatic select should not strand the grid on the wrong page).
  defp roll_month(socket, day) do
    month = month_iso(day)
    if month == socket.assigns.month, do: socket, else: assign(socket, :month, month)
  end

  # --- helpers ------------------------------------------------------------------

  defp day_iso(%DateTime{} = datetime), do: Date.to_iso8601(DateTime.to_date(datetime))

  defp month_iso(%Date{} = day) do
    "#{day.year}-#{String.pad_leading(Integer.to_string(day.month), 2, "0")}"
  end

  defp month_of(<<year::binary-size(4), "-", month::binary-size(2), _::binary>>),
    do: "#{year}-#{month}"

  # The lane vocabulary the app's badges and the NB status dots share.
  # Scheduled days wear their triage color; a visit in the room is violet
  # wherever it is in the lifecycle; the tail states go quiet.
  defp status_vocab(%Appointment{status: :scheduled, triage_urgency: urgency}) do
    case urgency do
      :emergency -> "emergency"
      :urgent -> "high"
      :soon -> "medium"
      :routine -> "low"
      _ -> "booked"
    end
  end

  defp status_vocab(%Appointment{status: :checked_in}), do: "visit"
  defp status_vocab(%Appointment{status: :completed}), do: "discharged"
  defp status_vocab(%Appointment{}), do: "closed"

  # The sheet's status chip mirrors the dot fill — static class strings so
  # the Tailwind scan sees every color.
  defp status_fill(%Appointment{} = appointment) do
    case status_vocab(appointment) do
      "booked" -> "bg-main"
      "low" -> "bg-green"
      "medium" -> "bg-yellow"
      "high" -> "bg-orange"
      "emergency" -> "bg-red"
      "visit" -> "bg-violet"
      "discharged" -> "bg-cyan"
      _ -> "bg-neutral"
    end
  end

  defp status_label(%Appointment{} = appointment) do
    case status_vocab(appointment) do
      "booked" -> "Booked"
      "low" -> "Triage: routine"
      "medium" -> "Triage: soon"
      "high" -> "Triage: urgent"
      "emergency" -> "Emergency"
      "visit" -> "In visit"
      "discharged" -> "Discharged"
      _ -> "Closed"
    end
  end

  defp time_range(%Appointment{} = appointment) do
    start_time = Calendar.strftime(appointment.scheduled_at, "%H:%M")

    end_time =
      appointment.scheduled_at
      |> DateTime.add((appointment.duration_minutes || 30) * 60, :second)
      |> Calendar.strftime("%H:%M")

    "#{start_time}–#{end_time}"
  end

  defp day_heading(%Date{} = day) do
    Calendar.strftime(day, "%A, %-d %B %Y")
  end
end
