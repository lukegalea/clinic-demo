# One mount module per surface — the whole LiveView is the LiveRenderer use,
# pointed at a standalone UI module and the actor the session hook assigns.
#
# Every surface here wires `ClinicDemoWeb.A2ui.SurfaceChrome`: presence is
# mounted for the acting clinician on the surface's topic (the tracker —
# the nav row's chips in `NavPresenceLive` are the SNAPSHOT view of those
# topics), and `handle_info/2` routes presence broadcasts to the refresh
# contract while everything else falls through to the LiveRenderer.
defmodule ClinicDemoWeb.A2ui.Surface do
  @moduledoc false

  defmacro __using__(surface_id: surface_id) do
    quote do
      alias ClinicDemoWeb.A2ui.SurfaceChrome

      @doc false
      @impl true
      def mount(params, session, socket) do
        {:ok, socket} = AshA2ui.LiveRenderer.mount(__ash_a2ui_config__(), params, session, socket)
        {:ok, SurfaceChrome.mount_presence(socket, unquote(surface_id))}
      end

      @doc false
      @impl true
      def handle_info(msg, socket) do
        SurfaceChrome.handle_info(msg, __ash_a2ui_config__(), socket)
      end

      defoverridable mount: 3, handle_info: 2
    end
  end
end

defmodule ClinicDemoWeb.A2ui.BoardLive do
  # Host-layer helpers for the time-travel control: the core components
  # (<.input>) and the verified-routes sigil. Imported directly rather than
  # `use ClinicDemoWeb, :live_view`, which would declare the LiveView
  # behaviour a second time next to the LiveRenderer's injected callbacks.
  import ClinicDemoWeb.CoreComponents

  use Phoenix.VerifiedRoutes,
    endpoint: ClinicDemoWeb.Endpoint,
    router: ClinicDemoWeb.Router,
    statics: ClinicDemoWeb.static_paths()

  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.BoardUI,
    actor_fn: & &1.assigns.a2ui_actor

  use ClinicDemoWeb.A2ui.Surface, surface_id: "clinic_board"

  alias ClinicDemoWeb.A2ui.AsOfSurface

  @moduledoc """
  The clinic board, with time travel.

  Without `?as_of=` this is the live board, byte-identical to every other
  surface host. With `?as_of=<iso8601>` the surface renders from the
  appointment history at that instant (`AsOfSurface` reads the temporal
  resource contained at T and strips the row actions — a view of the past
  is not an operating surface). The control below is the demo's handle on
  that: pick an instant, land on it as a shareable `?as_of=` deep link
  (the preset chips are quick jumps — the param still carries the exact
  instant); "Now" is the plain board again. An instant before any
  appointment existed gets a quiet line saying so, not a silent board.
  """

  # The control is composed as ONE bar with the actor notice so the host
  # chrome above the board reads as a single unit: the time-travel row on
  # top, and — only when nobody is acting — the actor notice as a black
  # strip docked into the same card. Without an acting clinician, every
  # card action is refused by the actor_present policy — the error surfaces
  # in the a2ui status banner inside the shadow DOM, which reads as "the
  # button didn't work". That strip says why, before the click.
  #
  # Time travel is a MODE, and the bar wears it: resting is the white card
  # with a green "Live now" chip; traveling turns the card violet with the
  # black "Viewing as of … · read-only" chip. The fill flip transitions, so
  # the "Now" reset reads as snapping back to live.
  #
  # Reaching /acting-as is live navigation — the picker now shares this
  # live_session. The actor SWITCH itself is still a full redirect by
  # design: ActorPlug writes the session over HTTP and 302s back.
  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <section
        aria-label="Board time travel"
        class={[
          "rounded-base border-2 border-border shadow-shadow transition-colors duration-300",
          if(@as_of, do: "bg-violet", else: "bg-secondary-background")
        ]}
      >
        <div class="flex flex-wrap items-center gap-x-4 gap-y-3 px-4 py-3">
          <.form
            for={@time_travel_form}
            id="time-travel-form"
            phx-change="set-as-of"
            class="flex flex-wrap items-center gap-x-2 gap-y-1 [&>div]:mb-0"
          >
            <label for="time-travel-as_of" class="text-sm font-heading">
              View the board as of
            </label>
            <.input
              type="datetime-local"
              field={@time_travel_form[:as_of]}
              id="time-travel-as_of"
              value={as_of_input_value(@as_of)}
              class="h-9 w-56 rounded-base border-2 border-border bg-secondary-background px-2.5 text-sm font-base shadow-shadow transition-all hover:shadow-lift focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-black"
            />
          </.form>
          <nav aria-label="Preset instants" class="flex flex-wrap items-center gap-1.5">
            <.link
              :for={{label, instant, id} <- time_travel_presets()}
              patch={time_travel_patch(instant)}
              data-testid={"tt-preset-#{id}"}
              title={preset_title(instant)}
              aria-current={if(preset_current?(instant, @as_of), do: "true", else: nil)}
              class={[
                "inline-flex h-9 items-center justify-center gap-1.5 whitespace-nowrap rounded-base border-2 border-border px-2.5 text-xs font-heading shadow-shadow ring-offset-white transition-all focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-black hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press",
                if(preset_current?(instant, @as_of),
                  do: "bg-main text-main-foreground",
                  else: "bg-secondary-background text-foreground"
                )
              ]}
            >
              <.icon :if={is_nil(instant)} name="hero-arrow-uturn-left" class="size-3.5" />
              {label}
            </.link>
          </nav>
          <span
            :if={is_nil(@as_of)}
            data-testid="as-of-live-indicator"
            role="status"
            class="tt-status-chip ml-auto inline-flex items-center gap-1.5 rounded-base border-2 border-border bg-green px-2.5 py-1 text-xs font-heading text-foreground"
          >
            <span class="size-2 rounded-full bg-foreground"></span> Live now
          </span>
          <span
            :if={@as_of}
            data-testid="as-of-indicator"
            role="status"
            class="tt-status-chip ml-auto inline-flex items-center gap-1.5 rounded-base border-2 border-border bg-black px-2.5 py-1 text-xs font-base text-white"
          >
            <.icon name="hero-clock" class="size-3.5 shrink-0" /> Viewing as of
            <span class="font-heading tabular-nums">{as_of_label(@as_of)}</span>
            · read-only
          </span>
        </div>
        <%= if is_nil(assigns[:a2ui_actor]) do %>
          <div class="mt-3 rounded-b-base bg-black px-4 py-2.5 text-sm text-white">
            <strong class="font-heading">No one is acting.</strong>
            Every move on the board needs a clinician —
            <.link navigate="/acting-as" class="underline underline-offset-2">pick one</.link>
            to enable check-ins, triage, and discharges.
          </div>
        <% end %>
      </section>
      <div
        :if={@as_of && @as_of_empty}
        data-testid="as-of-empty-state"
        class="flex items-center gap-2.5 rounded-base border-2 border-dashed border-border bg-secondary-background px-4 py-2.5 text-sm text-foreground/70"
      >
        <.icon name="hero-clock" class="size-4 shrink-0 text-foreground/50" />
        <p>
          <span class="font-heading text-foreground">No appointments yet at this instant.</span>
          The clinic's history starts later.
        </p>
      </div>
      <%!-- A card carries up to three transition buttons beside the patient's
           name and compliance chip; at ash_a2ui's 18rem default lane width
           they are cut off. The lanes scroll inside the board instead. --%>
      <div class="[--a2ui-board-lane-min-width:32rem]">
        <AshA2ui.LiveRenderer.surface_container />
      </div>
    </div>
    """
  end

  # The LiveRenderer's injected mount starts the surface build with the
  # compile-time config; when the request carries `?as_of=`, the build must
  # go through the as-of surface_fn instead, so mount swaps the config copy
  # before handing the call through. (mount/3 is defoverridable at both
  # layers; this override replaces the Surface macro's, preserving its
  # presence wiring.)
  @impl true
  def mount(params, session, socket) do
    as_of = as_of_from_params(params)
    config = surface_config(as_of)

    {:ok, socket} = AshA2ui.LiveRenderer.mount(config, params, session, socket)

    {:ok,
     socket
     |> SurfaceChrome.mount_presence("clinic_board")
     |> Phoenix.Component.assign(:as_of, as_of)
     |> assign_as_of_emptiness(as_of)
     # The picker's form: param-only (no changeset behind it) — the change
     # event is what matters, the input's value follows @as_of.
     |> Phoenix.Component.assign(:time_travel_form, to_form(%{}, as: :time_travel))}
  end

  # Live navigation: picking an instant re-runs the surface build (same
  # async task the mount used, so the injected handle_async delivers it the
  # same way). An absent or unparseable `?as_of=` is the present — the
  # DayLive `?date=` convention.
  @impl true
  def handle_params(params, _uri, socket) do
    as_of = as_of_from_params(params)

    if as_of == socket.assigns.as_of do
      # The mount already built (or skipped) the surface for this instant.
      {:noreply, socket}
    else
      config = surface_config(as_of)
      actor = socket.assigns.ash_a2ui_actor
      tenant = socket.assigns.ash_a2ui_tenant

      {:noreply,
       socket
       |> Phoenix.Component.assign(:as_of, as_of)
       |> assign_as_of_emptiness(as_of)
       |> start_async(:ash_a2ui_surface, fn ->
         config.ui
         |> config.surface_fn.(actor: actor, tenant: tenant)
         |> as_rebuild()
       end)}
    end
  end

  # A rebuild, not a bootstrap: the client already holds this surface, and
  # the A2UI message processor rejects a createSurface for a live id
  # ("Surface clinic_board already exists"), dropping the batch and leaving
  # the old cards on screen. Deleting it first lets the new build render.
  defp as_rebuild([%{"createSurface" => %{"surfaceId" => id}} = create | _] = messages) do
    [%{"version" => create["version"], "deleteSurface" => %{"surfaceId" => id}} | messages]
  end

  defp as_rebuild(messages), do: messages

  @impl true
  def handle_event("set-as-of", %{"time_travel" => %{"as_of" => raw}}, socket)
      when is_binary(raw) do
    case String.trim(raw) do
      "" ->
        # An emptied picker reads as "back to the present".
        {:noreply, push_patch(socket, to: ~p"/")}

      trimmed ->
        case AsOfSurface.parse(trimmed) do
          {:ok, as_of} ->
            {:noreply, push_patch(socket, to: ~p"/?as_of=#{DateTime.to_iso8601(as_of)}")}

          :error ->
            # Unparseable input leaves the URL — and therefore the board —
            # where it is.
            {:noreply, socket}
        end
    end
  end

  # Everything else belongs to the renderer: row actions ("a2ui:action"),
  # function responses, surface opens. The renderer's handle_event/3 is
  # overridable, so defining set-as-of above replaced it outright; without
  # this clause every board button crashed the LiveView.
  def handle_event(event, params, socket), do: super(event, params, socket)

  # The empty-state read: one containment read pinned to the instant — the
  # same query shape AsOfSurface's lane reads run (for_read → as_of → read)
  # — so the host chrome can say "nothing existed yet" instead of rendering
  # a silent board over an empty history. Only runs while traveling: the
  # live board tells its own story (or not) inside the surface.
  defp assign_as_of_emptiness(socket, nil) do
    Phoenix.Component.assign(socket, :as_of_empty, false)
  end

  defp assign_as_of_emptiness(socket, %DateTime{} = as_of) do
    empty? =
      ClinicDemo.Scheduling.Appointment
      |> Ash.Query.for_read(:read)
      |> Ash.Query.as_of(as_of)
      |> Ash.read!(authorize?: false)
      |> Enum.empty?()

    Phoenix.Component.assign(socket, :as_of_empty, empty?)
  end

  # The quick jumps. Each chip carries its exact instant in the `?as_of=`
  # param (the URL stays the source of truth — chips are shortcuts, not a
  # second mechanism), computed at render time so "1h ago" stays honest
  # however long the page sits open. "Now" is the reset: no param at all.
  defp time_travel_presets(now \\ DateTime.utc_now()) do
    today = DateTime.to_date(now)

    [
      {"Now", nil, "now"},
      {"1h ago", minutes_ago(now, 60), "1h-ago"},
      {"Today 08:00", at_time(today, ~T"08:00:00"), "today-0800"},
      {"Yesterday", at_time(Date.add(today, -1), ~T"08:00:00"), "yesterday"}
    ]
  end

  defp minutes_ago(now, minutes) do
    now |> DateTime.add(-minutes * 60, :second) |> DateTime.truncate(:second)
  end

  defp at_time(date, %Time{} = time) do
    DateTime.new!(date, time, "Etc/UTC")
  end

  defp time_travel_patch(nil), do: ~p"/"

  defp time_travel_patch(%DateTime{} = instant) do
    ~p"/?as_of=#{DateTime.to_iso8601(instant)}"
  end

  # A chip is "current" when the board is already at its instant — the
  # blue "you are here" fill, the same read as active tabs and nav pills.
  # Instants are second-truncated on both sides (presets by construction,
  # params by the ISO round-trip), so equality is exact.
  defp preset_current?(instant, as_of), do: instant == as_of

  defp preset_title(nil), do: "Back to the live board"

  defp preset_title(%DateTime{} = instant), do: as_of_label(instant)

  # The indicator's copy: the app's all-times-UTC convention, stated once,
  # quietly, inside the timestamp itself.
  defp as_of_label(%DateTime{} = as_of), do: Calendar.strftime(as_of, "%Y-%m-%d %H:%M UTC")

  # The compile-time config, or a copy whose surface_fn pins the reads to
  # the instant (the closure is what carries `as_of` into the async build —
  # `:surface_fn` receives only (ui, opts), so the instant cannot ride the
  # opts list).
  defp surface_config(nil), do: __ash_a2ui_config__()

  defp surface_config(as_of) do
    config = __ash_a2ui_config__()

    %{
      config
      | surface_fn: fn ui, opts -> AsOfSurface.build(ui, Keyword.put(opts, :as_of, as_of)) end
    }
  end

  defp as_of_from_params(%{"as_of" => raw}) when is_binary(raw) do
    case AsOfSurface.parse(raw) do
      {:ok, as_of} -> as_of
      :error -> nil
    end
  end

  defp as_of_from_params(_params), do: nil

  defp as_of_input_value(nil), do: nil
  defp as_of_input_value(%DateTime{} = as_of), do: Calendar.strftime(as_of, "%Y-%m-%dT%H:%M")
end

defmodule ClinicDemoWeb.A2ui.IntakeLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.IntakeUI,
    actor_fn: & &1.assigns.a2ui_actor

  use ClinicDemoWeb.A2ui.Surface, surface_id: "clinic_intake"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <%!-- The patient picker's host side: the a2ui combobox contract. The
           IntakeUI declares option_search [:name] on :patient_id, so the
           encoder emits the searchable-select composite under the frozen
           id contract (form_select_patient_id and its descendants); the
           shipped catalog upgrades it into a real typeahead. The data
           attrs mirror that contract on the host chrome (see
           AshA2ui.Combobox's moduledoc) and the hook observes it — focus
           hand-off and host affordances hang off this seam. The id is
           not decoration: a phx-hook element without a DOM id makes the
           LiveView client log "no DOM ID for hook" on every mount. It
           names the host chrome, outside the composite's frozen
           form_select_patient_id* namespace. --%>
      <div
        id="intake_patient_id_combobox"
        phx-hook="AshA2uiCombobox"
        {AshA2ui.Combobox.data_attrs(field: "patient_id", searchable: true)}
      >
        <AshA2ui.LiveRenderer.surface_container />
      </div>
    </div>
    """
  end
end

defmodule ClinicDemoWeb.A2ui.ScheduleLive do
  alias ClinicDemoWeb.A2ui.Links

  # The patient and clinician columns are reference links; opening one
  # lands on that surface with the record selected.
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.AppointmentUI,
    actor_fn: & &1.assigns.a2ui_actor,
    open_surface: &Links.open/2

  use ClinicDemoWeb.A2ui.Surface, surface_id: "clinic_schedule"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <%= if is_nil(assigns[:a2ui_actor]) do %>
        <div class="relative w-full rounded-base border-2 border-border bg-black px-4 py-3 text-sm text-white shadow-shadow">
          <strong class="font-heading">No one is acting.</strong>
          <%!-- Live navigation, same live_session. The switch itself is
               still a redirect by design (ActorPlug writes the session and
               302s back). --%>
          Booking and transitions need a clinician —
          <.link navigate="/acting-as" class="underline underline-offset-2">pick one</.link>
          to enable them.
        </div>
      <% end %>
      <AshA2ui.LiveRenderer.surface_container />
    </div>
    """
  end
end

defmodule ClinicDemoWeb.A2ui.WorklistLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.WorklistUI,
    actor_fn: & &1.assigns.a2ui_actor

  use ClinicDemoWeb.A2ui.Surface, surface_id: "clinic_worklist"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <AshA2ui.LiveRenderer.surface_container />
    </div>
    """
  end
end

defmodule ClinicDemoWeb.A2ui.VisitsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.VisitInstanceUI,
    actor_fn: & &1.assigns.a2ui_actor

  use ClinicDemoWeb.A2ui.Surface, surface_id: "clinic_visits"

  # The surface shows where each visit stands; the operator hub's recent
  # instances carry the per-instance context — each opens the BPMN viewer's
  # live token overlay.
  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <AshA2ui.LiveRenderer.surface_container />
      <div class="flex flex-wrap gap-2">
        <.link
          href="/operator#recent-instances"
          class="inline-flex h-9 items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 border-border bg-secondary-background px-3 text-sm font-base text-foreground shadow-shadow ring-offset-white transition-all hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press"
        >
          Open instances in the process viewer
        </.link>
      </div>
    </div>
    """
  end
end

defmodule ClinicDemoWeb.A2ui.PatientsLive do
  # deep_link: the selected patient rides the URL (?ctx[patient]=<id>), so a pick
  # is shareable and back-button friendly, and the schedule's links land on it.
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.PatientUI,
    actor_fn: & &1.assigns.a2ui_actor,
    deep_link: true

  use ClinicDemoWeb.A2ui.Surface, surface_id: "clinic_patients"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <AshA2ui.LiveRenderer.surface_container />
    </div>
    """
  end
end

defmodule ClinicDemoWeb.A2ui.CliniciansLive do
  # deep_link: the selected clinician rides the URL (?ctx[clinician]=<id>), so a pick
  # is shareable and back-button friendly, and the schedule's links land on it.
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.ClinicianUI,
    actor_fn: & &1.assigns.a2ui_actor,
    deep_link: true

  use ClinicDemoWeb.A2ui.Surface, surface_id: "clinic_clinicians"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <AshA2ui.LiveRenderer.surface_container />
    </div>
    """
  end
end

defmodule ClinicDemoWeb.A2ui.ProcessesLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.ProcessUI,
    actor_fn: & &1.assigns.a2ui_actor

  use ClinicDemoWeb.A2ui.Surface, surface_id: "clinic_process_definitions"

  # The surface shows the what; these links give the where-to-go. The
  # published version is read-only by construction — the designer is where
  # the next version gets drawn.
  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <AshA2ui.LiveRenderer.surface_container />
      <div class="flex flex-wrap gap-2">
        <%!-- Live navigation: the designer is inside live_session :a2ui. --%>
        <.link
          navigate="/operator/processes/appointment_visit/designer"
          class="inline-flex h-9 items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 border-border bg-secondary-background px-3 text-sm font-base text-foreground shadow-shadow ring-offset-white transition-all hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press"
        >
          Draw appointment_visit in the designer
        </.link>
      </div>
    </div>
    """
  end
end

defmodule ClinicDemoWeb.A2ui.DecisionTablesLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.DecisionTableUI,
    actor_fn: & &1.assigns.a2ui_actor

  use ClinicDemoWeb.A2ui.Surface, surface_id: "clinic_decision_definitions"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <AshA2ui.LiveRenderer.surface_container />
      <div class="flex flex-wrap gap-2">
        <%!-- Live navigation: the DMN editor is inside live_session :a2ui. --%>
        <.link
          navigate="/operator/decisions/appointment.triage/editor"
          class="inline-flex h-9 items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 border-border bg-secondary-background px-3 text-sm font-base text-foreground shadow-shadow ring-offset-white transition-all hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press"
        >
          Edit appointment.triage in the DMN editor
        </.link>
      </div>
    </div>
    """
  end
end

defmodule ClinicDemoWeb.A2ui.EmergencyBoardLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.EmergencyBoardUI,
    actor_fn: & &1.assigns.a2ui_actor

  use ClinicDemoWeb.A2ui.Surface, surface_id: "clinic_emergency_board"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <AshA2ui.LiveRenderer.surface_container />
    </div>
    """
  end
end

defmodule ClinicDemoWeb.A2ui.EvaluationsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.EvaluationUI,
    actor_fn: & &1.assigns.a2ui_actor

  use ClinicDemoWeb.A2ui.Surface, surface_id: "clinic_evaluations"

  # Decision evidence and the raw audit feed answer different questions —
  # "what did the rule decide?" versus "what did anyone do?" — so the two
  # surfaces link to each other.
  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <AshA2ui.LiveRenderer.surface_container />
      <div class="flex flex-wrap gap-2">
        <%!-- Live navigation: /events is inside live_session :a2ui. --%>
        <.link
          navigate="/events"
          class="inline-flex h-9 items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 border-border bg-secondary-background px-3 text-sm font-base text-foreground shadow-shadow ring-offset-white transition-all hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press"
        >
          Open the audit event log
        </.link>
      </div>
    </div>
    """
  end
end

defmodule ClinicDemoWeb.A2ui.EventsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.EventUI,
    actor_fn: & &1.assigns.a2ui_actor

  use ClinicDemoWeb.A2ui.Surface, surface_id: "clinic_events"

  # The audit feed's companion: the decision evidence surface. Same link,
  # read from the other side.
  #
  # The count is cheap (one aggregate read) and honest: a fresh, unseeded
  # database has no events, and this says so rather than rendering a bare
  # header over nothing. On any database that has seen the seed — or any
  # action at all — the message stays gone.
  @impl true
  def mount(params, session, socket) do
    {:ok, socket} = super(params, session, socket)

    event_count =
      ClinicDemo.Events.Event
      |> Ash.Query.new()
      |> Ash.count(authorize?: false)
      |> case do
        {:ok, count} -> count
        _ -> 0
      end

    {:ok, Phoenix.Component.assign(socket, :event_count, event_count)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <div
        :if={@event_count == 0}
        class="relative w-full rounded-base border-2 border-border bg-secondary-background px-4 py-6 text-sm text-foreground shadow-shadow"
        data-testid="events-empty-state"
      >
        <strong class="font-heading">No Event records yet.</strong>
        The audit log is read-only by construction, and nothing has appended
        to it. Actions taken on the surfaces will land here, newest first.
      </div>
      <AshA2ui.LiveRenderer.surface_container />
      <div
        class="relative w-full rounded-base border-2 border-border bg-secondary-background px-4 py-6 text-sm text-foreground shadow-shadow"
        data-testid="replay-note"
      >
        <strong class="font-heading">This log is the story of the audited half.</strong>
        A cold clone — an empty database against this file of events —
        rebuilds every resource that rides the log by replaying it through
        the same attributed actions, chronologically, writing nothing new:
        appointment history with its period splits, patients and
        clinicians, revenue charges, DMN evaluations — and the judgment
        record: observation ledger rows (their inputs complete, so no model
        is ever consulted) and the admitted acuity fact periods, rebuilt
        identically to how they were materialised live. The process engine
        deliberately keeps its own trail instead of doubling it here, and
        what the log does not carry does not come back — which is why every
        audited write rides an event, and nothing mends state behind the
        log's back.
      </div>
      <div class="flex flex-wrap gap-2">
        <%!-- Live navigation: /evaluations is inside live_session :a2ui. --%>
        <.link
          navigate="/evaluations"
          class="inline-flex h-9 items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 border-border bg-secondary-background px-3 text-sm font-base text-foreground shadow-shadow ring-offset-white transition-all hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press"
        >
          Open the decision evidence
        </.link>
      </div>
    </div>
    """
  end
end
