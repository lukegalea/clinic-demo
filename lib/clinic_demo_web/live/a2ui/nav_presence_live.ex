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

  # The nav's clinic cluster (sm density, presence chips kept): the
  # working set — board, day, flight, intake, schedule, worklist, visits.
  # The operator/system routes collapsed into the Operator hub pill
  # (CLIN-10 §4: nav is clinic-first, the operator area is one door);
  # their presence topics AGGREGATE onto that pill so who-else-is-here
  # survives the collapse.
  @clinic_entries [
    {"Board", "/", "clinic_board"},
    {"Day", "/day", "clinic_day"},
    {"Flight", "/flight", "clinic_flight"},
    {"Intake", "/intake", "clinic_intake"},
    {"Schedule", "/schedule", "clinic_schedule"},
    {"Worklist", "/worklist", "clinic_worklist"},
    {"Visits", "/visits", "clinic_visits"}
  ]

  # The collapsed operator cluster: {path, surface_id}. Their pills are
  # cards on /operator; their presence merges into the Operator pill.
  @operator_entries [
    {"/patients", "clinic_patients"},
    {"/clinicians", "clinic_clinicians"},
    {"/processes", "clinic_process_definitions"},
    {"/decisions", "clinic_decision_definitions"},
    {"/evaluations", "clinic_evaluations"}
  ]

  @presence_events ["presence_state", "presence_diff"]

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      for {_label, _path, surface_id} <- @clinic_entries do
        Presence.subscribe(A2uiPresence, surface_id)
      end

      for {_path, surface_id} <- @operator_entries do
        Presence.subscribe(A2uiPresence, surface_id)
      end
    end

    actor_id = session["actor_id"]
    {clinic, operator_others} = snapshot(actor_id)

    {:ok,
     assign(socket,
       actor_id: actor_id,
       current_path: session["current_path"] || "",
       snapshot: clinic,
       operator_others: operator_others
     )}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: event}, socket)
      when event in @presence_events do
    {clinic, operator_others} = snapshot(socket.assigns.actor_id)

    {:noreply,
     assign(socket,
       snapshot: clinic,
       operator_others: operator_others
     )}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <nav
      class="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto"
      aria-label="Main"
      data-testid="nav-presence"
    >
      <.nav_pill :for={entry <- @snapshot} entry={entry} current_path={@current_path} />
      <%!-- The Operator hub: a plain controller page (full load, not live
           navigation) carrying the collapsed operator/system routes, with
           their presence aggregated — the one door into the operator
           area. --%>
      <a class={pill_class()} href="/operator" {PresenceBar.nav_current_attrs(@current_path, "/operator")}>
        Operator
        <.chips others={@operator_others} label="Operator" />
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

  # The sm-density pill, per the digest's Menubar spec: FLAT at rest —
  # the transparent border-2 RESERVES the outline's space so the hover
  # state cannot shift layout — and hover/open is the full inversion
  # (bg-main, black text, border turns black). No shadow, no translate:
  # nav is chrome; only the objects below carry shadows.
  defp pill_class do
    "inline-flex h-8 flex-none items-center justify-center gap-2 rounded-full border-2 border-transparent px-3 text-xs font-base text-foreground transition-colors focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-black focus-visible:ring-offset-2 hover:border-border hover:bg-main hover:text-main-foreground aria-current:border-border aria-current:bg-main aria-current:text-main-foreground"
  end

  # The clinic snapshot: per-surface others. The operator pill's others
  # AGGREGATE the collapsed routes' topics (deduped by key — one clinician
  # on two operator surfaces is one chip).
  defp snapshot(actor_id) do
    clinic =
      Enum.map(@clinic_entries, fn {label, path, surface_id} ->
        others =
          Presence.list(A2uiPresence, surface_id)
          |> Enum.reject(&(&1.key == actor_id))

        %{label: label, path: path, others: others}
      end)

    operator_others =
      @operator_entries
      |> Enum.flat_map(fn {_path, surface_id} -> Presence.list(A2uiPresence, surface_id) end)
      |> Enum.uniq_by(& &1.key)
      |> Enum.reject(&(&1.key == actor_id))

    {clinic, operator_others}
  end
end
