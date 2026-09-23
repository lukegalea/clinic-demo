defmodule ClinicDemoWeb.A2ui.NavPresenceLive do
  @moduledoc """
  The nav menu row as a live region: every nav pill, plus the per-route
  presence chips.

  Who-else-is-here moved from the surface headers into the nav: under each
  nav entry, compact initials chips show who else is on that route right
  now. The whole row is one small child LiveView because the chips are
  reactive — the static root layout renders once per document, and live
  navigation within `live_session :a2ui` never re-renders it.

  The snapshot is nav-wide: this LiveView tracks NOBODY (the surface
  LiveViews remain the trackers, per surface) — it subscribes to every nav
  surface's presence topic and re-lists all of them on ANY presence
  broadcast, so the chips move when someone lands on another route.

  Others only: a visitor's own row is filtered out by their stable key
  (the clinician id). Self is expressed by the active nav styling —
  `aria-current="page"` via `AshA2ui.PresenceBar.nav_current_attrs/2` —
  never by an avatar. Anonymous visitors have no stable key, so the filter
  is a no-op for them and they see every tracked clinician.

  Chips are compact: at most three initials circles, overflowing into a
  "+N" chip. `aria-current` accuracy is per document load (live
  navigation keeps the document — and this value — as-is, like the rest
  of the chrome).
  """

  use Phoenix.LiveView

  alias AshA2ui.Presence
  alias AshA2ui.PresenceBar
  alias ClinicDemoWeb.A2uiPresence

  # The nav's a2ui entries: {label, path, surface_id}. /operator is a
  # controller page with no presence topic and is appended in the render.
  @entries [
    {"Board", "/", "clinic_board"},
    {"Intake", "/intake", "clinic_intake"},
    {"Schedule", "/schedule", "clinic_schedule"},
    {"Worklist", "/worklist", "clinic_worklist"},
    {"Visits", "/visits", "clinic_visits"},
    {"Patients", "/patients", "clinic_patients"},
    {"Clinicians", "/clinicians", "clinic_clinicians"},
    {"Processes", "/processes", "clinic_process_definitions"},
    {"Decisions", "/decisions", "clinic_decision_definitions"},
    {"Evidence", "/evaluations", "clinic_evaluations"}
  ]

  @presence_events ["presence_state", "presence_diff"]

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      for {_label, _path, surface_id} <- @entries do
        Presence.subscribe(A2uiPresence, surface_id)
      end
    end

    actor_id = session["actor_id"]

    {:ok,
     assign(socket,
       actor_id: actor_id,
       current_path: session["current_path"] || "",
       snapshot: snapshot(actor_id)
     )}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: event}, socket)
      when event in @presence_events do
    {:noreply, assign(socket, :snapshot, snapshot(socket.assigns.actor_id))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <nav class="flex flex-wrap gap-1.5" aria-label="Main" data-testid="nav-presence">
      <.nav_pill :for={entry <- @snapshot} entry={entry} current_path={@current_path} />
      <%!-- /operator is a plain controller page, not a LiveView, so there
           is nothing to navigate to — this one stays a full load. --%>
      <a
        class={pill_class()}
        href="/operator"
        {PresenceBar.nav_current_attrs(@current_path, "/operator")}
      >
        Operator
      </a>
    </nav>
    """
  end

  attr :entry, :map, required: true
  attr :current_path, :string, required: true

  defp nav_pill(assigns) do
    ~H"""
    <.link
      class={pill_class()}
      navigate={@entry.path}
      {PresenceBar.nav_current_attrs(@current_path, @entry.path)}
    >
      {@entry.label}
      <.chips others={@entry.others} label={@entry.label} />
    </.link>
    """
  end

  attr :others, :list, required: true
  attr :label, :string, required: true

  defp chips(assigns) do
    assigns =
      assigns
      |> assign(visible: Enum.take(assigns.others, 3))
      |> assign(overflow: max(0, length(assigns.others) - 3))

    ~H"""
    <span :if={@others != []} class="ml-1 inline-flex items-center">
      <span
        :for={{p, i} <- Enum.with_index(@visible)}
        class={
          "inline-flex size-5 items-center justify-center rounded-full border-2 border-border bg-secondary-background text-[9px] font-bold leading-none text-foreground" <>
            if(i > 0, do: " -ml-1.5", else: "")
        }
        title={"#{p.label} is on #{@label}"}
        aria-label={"#{p.label} is on #{@label}"}
      >
        {PresenceBar.initials(p.label)}
      </span>
      <span
        :if={@overflow > 0}
        class="-ml-1.5 inline-flex size-5 items-center justify-center rounded-full border-2 border-border bg-yellow text-[9px] font-bold leading-none text-foreground"
        aria-label={"#{@overflow} more on #{@label}"}
      >
        +{@overflow}
      </span>
    </span>
    """
  end

  # The nav pill classes, unchanged from the design lane's root layout.
  defp pill_class do
    "inline-flex h-9 items-center justify-center gap-2 whitespace-nowrap rounded-full border-2 border-border bg-secondary-background px-4 text-sm font-base text-foreground shadow-shadow ring-offset-white transition-all focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-black focus-visible:ring-offset-2 disabled:pointer-events-none disabled:opacity-50 hover:-translate-x-0.5 hover:-translate-y-0.5 hover:-rotate-1 hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press"
  end

  # The nav-wide snapshot: every nav surface topic, others only. A key is
  # the actor's stable id, so the caller's own row (tracked by whichever
  # surface LiveView they are on) is filtered out; nil (anonymous) matches
  # nothing and sees everyone.
  defp snapshot(actor_id) do
    Enum.map(@entries, fn {label, path, surface_id} ->
      others =
        Presence.list(A2uiPresence, surface_id)
        |> Enum.reject(&(&1.key == actor_id))

      %{label: label, path: path, others: others}
    end)
  end
end
