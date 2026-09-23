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
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.BoardUI,
    actor_fn: & &1.assigns.a2ui_actor

  use ClinicDemoWeb.A2ui.Surface, surface_id: "clinic_board"

  # Without an acting clinician, every card action is refused by the
  # actor_present policy — the error surfaces in the a2ui status banner
  # inside the shadow DOM, which reads as "the button didn't work". This
  # banner says why, before the click.
  #
  # Reaching /acting-as is live navigation — the picker now shares this
  # live_session. The actor SWITCH itself is still a full redirect by
  # design: ActorPlug writes the session over HTTP and 302s back.
  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <%= if is_nil(assigns[:a2ui_actor]) do %>
        <div class="relative w-full rounded-base border-2 border-border bg-black px-4 py-3 text-sm text-white shadow-shadow">
          <strong class="font-heading">No one is acting.</strong>
          Every move on the board needs a clinician —
          <.link navigate="/acting-as" class="underline underline-offset-2">pick one</.link>
          to enable check-ins, triage, and discharges.
        </div>
      <% end %>
      <AshA2ui.LiveRenderer.surface_container />
    </div>
    """
  end
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
           hand-off and host affordances hang off this seam. --%>
      <div
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
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.AppointmentUI,
    actor_fn: & &1.assigns.a2ui_actor

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

  # The surface shows where each visit stands; the engine's own task inbox
  # is the view that carries the per-instance context — the BPMN viewer's
  # live token overlay renders from there.
  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <AshA2ui.LiveRenderer.surface_container />
      <div class="flex flex-wrap gap-2">
        <%!-- Live navigation: /operator/tasks is inside live_session :a2ui,
             so the visit surface stays mounted while the browser moves. --%>
        <.link
          navigate="/operator/tasks"
          class="inline-flex h-9 items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 border-border bg-secondary-background px-3 text-sm font-base text-foreground shadow-shadow ring-offset-white transition-all hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press"
        >
          Open instances in the process viewer (via tasks)
        </.link>
      </div>
    </div>
    """
  end
end

defmodule ClinicDemoWeb.A2ui.PatientsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.PatientUI,
    actor_fn: & &1.assigns.a2ui_actor

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
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.ClinicianUI,
    actor_fn: & &1.assigns.a2ui_actor

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

defmodule ClinicDemoWeb.A2ui.ProcessDefinitionsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.ProcessDefinitionUI,
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

defmodule ClinicDemoWeb.A2ui.DecisionDefinitionsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.DecisionDefinitionUI,
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
  # The promised empty state used to live only inside the shadow DOM, where
  # the framework never rendered it — with zero rows the surface was a
  # header and a search box over nothing, no matter what it promised. The
  # count is cheap (one aggregate read) and honest: when the projector
  # starts appending, the message leaves on its own.
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
