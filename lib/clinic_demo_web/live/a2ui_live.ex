# One mount module per surface — the whole LiveView is the LiveRenderer use,
# pointed at a standalone UI module and the actor the session hook assigns.
defmodule ClinicDemoWeb.A2ui.BoardLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.BoardUI,
    actor_fn: & &1.assigns.a2ui_actor

  # Without an acting clinician, every card action is refused by the
  # actor_present policy — the error surfaces in the a2ui status banner
  # inside the shadow DOM, which reads as "the button didn't work". This
  # banner says why, before the click.
  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <%= if is_nil(assigns[:a2ui_actor]) do %>
        <div class="relative w-full rounded-base border-2 border-border bg-black px-4 py-3 text-sm text-white shadow-shadow">
          <strong class="font-heading">No one is acting.</strong>
          Every move on the board needs a clinician —
          <.link href="/acting-as" class="underline underline-offset-2">pick one</.link>
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
end

defmodule ClinicDemoWeb.A2ui.ScheduleLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.AppointmentUI,
    actor_fn: & &1.assigns.a2ui_actor

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <%= if is_nil(assigns[:a2ui_actor]) do %>
        <div class="relative w-full rounded-base border-2 border-border bg-black px-4 py-3 text-sm text-white shadow-shadow">
          <strong class="font-heading">No one is acting.</strong>
          Booking and transitions need a clinician —
          <.link href="/acting-as" class="underline underline-offset-2">pick one</.link>
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
end

defmodule ClinicDemoWeb.A2ui.VisitsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.VisitInstanceUI,
    actor_fn: & &1.assigns.a2ui_actor

  # The surface shows where each visit stands; the engine's own task inbox
  # is the view that carries the per-instance context — the BPMN viewer's
  # live token overlay renders from there.
  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <AshA2ui.LiveRenderer.surface_container />
      <div class="flex flex-wrap gap-2">
        <a
          href="/operator/tasks"
          class="inline-flex h-9 items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 border-border bg-secondary-background px-3 text-sm font-base text-foreground shadow-shadow ring-offset-white transition-all hover:translate-x-boxShadowX hover:translate-y-boxShadowY hover:shadow-none"
        >
          Open instances in the process viewer (via tasks)
        </a>
      </div>
    </div>
    """
  end
end

defmodule ClinicDemoWeb.A2ui.PatientsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.PatientUI,
    actor_fn: & &1.assigns.a2ui_actor
end

defmodule ClinicDemoWeb.A2ui.CliniciansLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.ClinicianUI,
    actor_fn: & &1.assigns.a2ui_actor
end

defmodule ClinicDemoWeb.A2ui.ProcessDefinitionsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.ProcessDefinitionUI,
    actor_fn: & &1.assigns.a2ui_actor

  # The surface shows the what; these links give the where-to-go. The
  # published version is read-only by construction — the designer is where
  # the next version gets drawn.
  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <AshA2ui.LiveRenderer.surface_container />
      <div class="flex flex-wrap gap-2">
        <a
          href="/operator/processes/appointment_visit/designer"
          class="inline-flex h-9 items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 border-border bg-secondary-background px-3 text-sm font-base text-foreground shadow-shadow ring-offset-white transition-all hover:translate-x-boxShadowX hover:translate-y-boxShadowY hover:shadow-none"
        >
          Draw appointment_visit in the designer
        </a>
      </div>
    </div>
    """
  end
end

defmodule ClinicDemoWeb.A2ui.DecisionDefinitionsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.DecisionDefinitionUI,
    actor_fn: & &1.assigns.a2ui_actor

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <AshA2ui.LiveRenderer.surface_container />
      <div class="flex flex-wrap gap-2">
        <a
          href="/operator/decisions/appointment.triage/editor"
          class="inline-flex h-9 items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 border-border bg-secondary-background px-3 text-sm font-base text-foreground shadow-shadow ring-offset-white transition-all hover:translate-x-boxShadowX hover:translate-y-boxShadowY hover:shadow-none"
        >
          Edit appointment.triage in the DMN editor
        </a>
      </div>
    </div>
    """
  end
end

defmodule ClinicDemoWeb.A2ui.EmergencyBoardLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.EmergencyBoardUI,
    actor_fn: & &1.assigns.a2ui_actor
end

defmodule ClinicDemoWeb.A2ui.EvaluationsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.EvaluationUI,
    actor_fn: & &1.assigns.a2ui_actor
end
